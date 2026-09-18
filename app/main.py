"""
社内ナレッジ検索RAG — バックエンドAPI
Phase 2: コンテナ化して ECS 上で動かす（Bedrock 疎通まで）。
Phase 3: /api/ask を RAG 化。質問 → Titan 埋め込み → pgvector 類似検索(Top-K) → 文脈として Claude に渡し、出典付きで回答。
      検索・プロンプト組み立ては rag.py、埋め込みは embeddings.py（取込 ingest.py と共用）。
"""
import os
import logging

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

import db
import rag

logger = logging.getLogger("rag-api")
logging.basicConfig(level=logging.INFO)


class UTF8JSONResponse(JSONResponse):
    """トラブルシュート記録#12対策: Content-Type に charset=utf-8 を明示する。
    無いと一部クライアント(PowerShell 5.1等)が Latin-1 と解釈して日本語が文字化けする。"""
    media_type = "application/json; charset=utf-8"


app = FastAPI(title="RAG API", default_response_class=UTF8JSONResponse)

# CORS: フロント(CloudFront)からブラウザ経由で叩けるように許可。
# ⚠️ 既定の "*" は動作確認用。本番/公開前は環境変数 ALLOWED_ORIGINS に
#    自分のCloudFrontドメインを設定して絞る（ECSのタスク定義で渡す）。
#    → コード変更ではなく設定変更で閉じられるようにしてある。
ALLOWED_ORIGINS = [
    o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "*").split(",") if o.strip()
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)

# リージョンは環境変数で渡す（ECSのタスク定義で設定）。無ければ東京。
REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "jp.anthropic.claude-sonnet-4-6")

# タイムアウトとリトライを明示する。
# 既定のまま放置すると、Bedrockが詰まった時にALBのidle timeout(60s)より先に
# こちらが待ち続けてしまい、原因の切り分けがしづらくなる。
_boto_config = Config(
    connect_timeout=5,
    read_timeout=50,
    retries={"max_attempts": 3, "mode": "standard"},
)

# boto3クライアントはプロセス起動時に1度だけ作る（毎リクエスト作らない）
bedrock = boto3.client("bedrock-runtime", region_name=REGION, config=_boto_config)


class AskRequest(BaseModel):
    question: str
    # RAG あり/なし比較用: false にすると RAG 導入前と同じ「検索なし・素の生成」になる。
    # 同じ質問で RAG あり/なし を並べて見せられる＝「RAGで何が変わったか」を実演できる。
    use_rag: bool = True
    # 省略時は環境変数 RAG_TOP_K（rag.py）。リクエスト単位で 3/5/10 を試す用
    top_k: int | None = None


@app.get("/health")
def health():
    """ALB/ECSのヘルスチェック用。DBやBedrockに依存させないのが定石
    （依存先が落ちてもヘルスチェックは通る＝コンテナ自体の生存確認）。"""
    return {"status": "ok"}


@app.get("/api/db-check")
def db_check():
    """RDS疎通確認用（Phase 3 で追加）。
    Phase 2 では「Execution Role が Secrets Manager からパスワードを取れる」までしか検証しておらず、
    アプリがDBに実際に接続したことは一度も無かった。この端点がその初検証。
    確認できること: SG(app-sg→rds-sg:5432) / 認証情報の注入 / pgvectorの有無 / 行数。"""
    try:
        with db.get_conn() as conn, conn.cursor() as cur:
            cur.execute("SHOW server_version;")
            pg_version = cur.fetchone()[0]
            cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'vector';")
            row = cur.fetchone()
            vector_version = row[0] if row else None
            cur.execute("SELECT to_regclass('public.documents');")
            table_exists = cur.fetchone()[0] is not None
            doc_count = 0
            if table_exists:
                cur.execute("SELECT count(*) FROM documents;")
                doc_count = cur.fetchone()[0]
    except KeyError as e:
        # DB_HOST等の環境変数が未設定＝タスク定義のsecrets設定漏れ
        logger.exception("DB env var missing")
        raise HTTPException(status_code=500, detail=f"missing env: {e}")
    except Exception:
        # 接続失敗の詳細(ホスト名等)はログのみに残し、外には出さない
        logger.exception("DB connection failed")
        raise HTTPException(status_code=502, detail="db connection failed")

    return {
        "status": "ok",
        "postgres": pg_version,
        "pgvector": vector_version,          # null なら CREATE EXTENSION 未実行
        "documents_table": table_exists,      # false なら init_db.py 未実行
        "documents_count": doc_count,
    }


@app.post("/api/ask")
def ask(req: AskRequest):
    """RAG 問答。
    1. 質問を Titan で埋め込み → pgvector で余弦距離の近い Top-K チャンクを取得（rag.search）
    2. 最上位の類似度が閾値未満なら **Claude を呼ばず** 「該当なし」を返す（幻覚対策③・課金ゼロ）
    3. Top-K を【参考資料】として並べ、システムプロンプトで「資料外は答えない」を制約して Claude 生成
    4. 回答 + 出典リスト（source / chunk_index / similarity / 抜粋）を返す
    """
    if not req.question.strip():
        raise HTTPException(status_code=400, detail="question is empty")
    if req.top_k is not None and not (1 <= req.top_k <= 20):
        raise HTTPException(status_code=400, detail="top_k must be 1..20")

    sources: list[dict] = []
    system: list[dict] = []
    user_text = req.question

    if req.use_rag:
        try:
            hits = rag.search(req.question, top_k=req.top_k or rag.TOP_K)
        except ClientError as e:
            # 埋め込み(Titan)側の失敗。生成側と同じ分類で返す
            logger.exception("Embedding ClientError: %s", e.response.get("Error", {}).get("Code"))
            raise HTTPException(status_code=502, detail="embedding failed")
        except Exception:
            # DB 接続失敗など。詳細はログのみ（ホスト名等を外に出さない）
            logger.exception("retrieval failed")
            raise HTTPException(status_code=502, detail="retrieval failed")

        sources = rag.to_sources(hits)
        if not rag.is_confident(hits):
            # 検索結果が無い/薄い → 生成しない。sources は「何が最も近かったか」の参考として返す
            top = hits[0].similarity if hits else None
            logger.info("low confidence (top=%s < %s): skip generation", top, rag.MIN_SIMILARITY)
            return {
                "answer": rag.NO_ANSWER_TEXT,
                "sources": sources,
                "rag": {"used": True, "generated": False, "top_k": len(hits),
                        "top_similarity": top, "min_similarity": rag.MIN_SIMILARITY},
                "tokens": {"input": 0, "output": 0},
            }
        system = [{"text": rag.SYSTEM_PROMPT}]
        user_text = rag.build_user_message(req.question, hits)

    try:
        kwargs = dict(
            modelId=MODEL_ID,
            messages=[{"role": "user", "content": [{"text": user_text}]}],
            # RAG 時は忠実性優先で temperature を下げる。素の生成(比較用)は RAG 導入前と同じ 0.7
            inferenceConfig={"maxTokens": 800, "temperature": 0.2 if req.use_rag else 0.7},
        )
        if system:
            kwargs["system"] = system
        response = bedrock.converse(**kwargs)
    except ClientError as e:
        # AWS側が返したエラー。詳細はログに残し、クライアントには最小限だけ返す
        # （エラー本文にはモデルIDやアカウント情報が混じり得るため、そのまま外に出さない）。
        code = e.response.get("Error", {}).get("Code", "Unknown")
        logger.exception("Bedrock ClientError: %s", code)
        if code in ("ThrottlingException", "TooManyRequestsException"):
            raise HTTPException(status_code=429, detail="model is busy, retry later")
        if code in ("AccessDeniedException", "UnrecognizedClientException"):
            # Task Role に bedrock:InvokeModel が無い時にここへ来る
            raise HTTPException(status_code=502, detail="model access denied")
        if code == "ValidationException":
            # 裸のモデルIDを指定した時などにここへ来る（トラブルシュート記録 #2 参照）
            raise HTTPException(status_code=502, detail="invalid model request")
        raise HTTPException(status_code=502, detail="model invocation failed")
    except BotoCoreError:
        # 接続・タイムアウト系
        logger.exception("Bedrock connection error")
        raise HTTPException(status_code=504, detail="model timeout")

    answer = response["output"]["message"]["content"][0]["text"]
    usage = response["usage"]
    return {
        "answer": answer,
        "sources": sources,
        "rag": {"used": req.use_rag, "generated": True, "top_k": len(sources),
                "top_similarity": sources[0]["similarity"] if sources else None,
                "min_similarity": rag.MIN_SIMILARITY},
        "tokens": {"input": usage["inputTokens"], "output": usage["outputTokens"]},
    }
