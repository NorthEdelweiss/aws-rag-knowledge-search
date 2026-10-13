"""
RAG の検索側: 質問 → 埋め込み → pgvector 類似検索 → Claude 用プロンプト組み立て。

main.py の /api/ask から呼ばれる。取込側(ingest.py)と **同じ embeddings.embed_text** を使うことが最重要
（モデル/次元/正規化がずれると保存済みベクトルと別空間になり、検索が「エラーなく」壊れる）。

このファイルが担う 3 つの設計判断:
  1. 距離: `<=>` = 余弦距離。Titan v2 は normalize=True で長さ1 → 余弦と内積(<#>)は等価。
     L2(<->) でなく余弦を選ぶのは「文の長さでなく向き(意味)だけで比べたい」から。
  2. Top-K: 環境変数 RAG_TOP_K（既定5）。コードを変えずタスク定義だけで 3/5/10 を比較できる。
  3. ハルシネーション対策: ①出典を必ず返す ②文脈外は答えないようシステムプロンプトで制約
     ③最高類似度が RAG_MIN_SIMILARITY 未満なら **生成せずに** 「該当なし」を返す（Bedrock 課金もゼロ）。
"""
import logging
import os
from dataclasses import dataclass

import db
from embeddings import embed_text, to_pgvector

log = logging.getLogger("rag")

TOP_K = int(os.environ.get("RAG_TOP_K", "5"))
# 余弦類似度(1 - 距離)の下限。Titan v2 日本語では「関連あり」≈0.4~0.7、「無関係」≈0.1~0.3 が体感値。
# 既定 0.25 は緩め（取りこぼしより誤検出を許す側）。実測で /api/ask の sources[].similarity を見て調整する。
MIN_SIMILARITY = float(os.environ.get("RAG_MIN_SIMILARITY", "0.25"))
# 出典として返す本文の長さ（全文は返さない: 画面に出す量と、社内文書を丸ごと外に出さない配慮）
EXCERPT_CHARS = 160

NO_ANSWER_TEXT = "資料内に該当情報が見つかりませんでした。"

# ⭐ 制約の書き方: 「文脈だけを使う」「無ければ無いと言う」「出典番号を付ける」の3点を明示。
#    temperature も低め(main.py 側で 0.2)にして、言い回しの創造性より忠実性を優先する。
SYSTEM_PROMPT = (
    "あなたは社内ナレッジ検索アシスタントです。\n"
    "以下のルールを厳守してください:\n"
    "1. 回答は必ず与えられた【参考資料】の内容のみに基づいて作成する。一般知識や推測で補わない。\n"
    f"2. 参考資料に質問への答えが含まれていない場合は、正確に「{NO_ANSWER_TEXT}」とだけ答える。\n"
    "3. 回答の根拠となった資料は文末に [1] [2] のように番号で示す。\n"
    "4. 日本語で、簡潔に答える。"
)


@dataclass
class Hit:
    source: str
    chunk_index: int
    content: str
    similarity: float   # 1 - 余弦距離。1.0 が完全一致


def search(question: str, top_k: int = TOP_K) -> list[Hit]:
    """質問を埋め込み、documents から余弦距離の近い順に top_k 件返す。

    インデックス無し＝全件順次スキャン。数千行までは HNSW を張るより速く、かつ近似でなく厳密。
    """
    qvec = to_pgvector(embed_text(question))
    with db.get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT source, chunk_index, content, 1 - (embedding <=> %(q)s::vector) AS similarity
            FROM documents
            ORDER BY embedding <=> %(q)s::vector
            LIMIT %(k)s;
            """,
            {"q": qvec, "k": top_k},
        )
        rows = cur.fetchall()
    hits = [Hit(source=r[0], chunk_index=r[1], content=r[2], similarity=float(r[3])) for r in rows]
    # 類似度はログに残す: 閾値/Top-K を決める材料。本文はログに出さない（社内文書をログに散らさない）
    log.info("search: k=%d hits=%s", top_k,
             [(h.source, h.chunk_index, round(h.similarity, 3)) for h in hits])
    return hits


def is_confident(hits: list[Hit]) -> bool:
    """最上位の類似度が閾値以上か。False なら Claude を呼ばずに NO_ANSWER_TEXT を返す（③）。"""
    return bool(hits) and hits[0].similarity >= MIN_SIMILARITY


def build_user_message(question: str, hits: list[Hit]) -> str:
    """検索結果を番号付きで文脈に並べ、その後に質問を置く。
    番号が出典 [n] と1対1対応する＝回答の根拠を人間が検証できる。"""
    parts = ["【参考資料】"]
    for i, h in enumerate(hits, start=1):
        parts.append(f"[{i}] （出典: {h.source} / 段落{h.chunk_index}）\n{h.content}")
    parts.append("")
    parts.append(f"【質問】\n{question}")
    return "\n\n".join(parts)


def to_sources(hits: list[Hit]) -> list[dict]:
    """API レスポンス用。本文は先頭 EXCERPT_CHARS 文字だけ。"""
    return [
        {
            "ref": i,
            "source": h.source,
            "chunk_index": h.chunk_index,
            "similarity": round(h.similarity, 3),
            "excerpt": h.content[:EXCERPT_CHARS] + ("…" if len(h.content) > EXCERPT_CHARS else ""),
        }
        for i, h in enumerate(hits, start=1)
    ]
def broken(: