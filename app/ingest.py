"""
文書取込ジョブ: S3(またはローカル) の文書 → チャンク分割 → Titan で埋め込み → documents に INSERT

実行方法（本番＝プライベートサブネット内）:
  ECS run-task + コマンド上書き:  python,ingest.py,--bucket,<文書バケット名>
  → RDS を公開せず・踏み台も立てず、既存のイメージ/ネットワーク/IAM をそのまま再利用する。

ローカル確認（DB 不要）:
  python ingest.py --local-dir ../sample_docs --dry-run              # 分割＋埋め込み(各文書1回)、INSERTしない
  python ingest.py --local-dir ../sample_docs --dry-run --skip-embed # 分割だけ（Bedrockも呼ばない）

対応形式: .txt / .md（そのまま） / .pdf（pypdf でテキスト抽出）

⭐ 冪等性: 同じ source を再取込すると、その source の既存行を DELETE してから INSERT する（同一トランザクション）。
   → ジョブが途中で失敗して再実行しても二重登録にならない。
"""
import argparse
import io
import logging
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("ingest")

# ---------------------------------------------------------------------------
# チャンク分割の設計値（設計の 3 論点: なぜこの大きさ／なぜ重ねる／大小のトレードオフ）
# ---------------------------------------------------------------------------
CHUNK_SIZE = 500      # 文字数の上限。400~600 が起点。
                      #   大きい → 1チャンクに複数話題が混ざりベクトルが"平均化"されて検索精度↓、プロンプトに入れる token↑
                      #   小さい → 文脈不足で、検索で当たっても答えるのに必要な情報が入っていない
CHUNK_OVERLAP = 80    # 前チャンク末尾を次チャンク先頭に重ねる文字数。
                      #   硬く切ると文や概念が真っ二つになる。境界をまたぐ内容が「どちらかには丸ごと入る」状態を作る
MIN_CHUNK_SIZE = 50   # これ未満の末尾断片は直前チャンクに併合（意味の無い断片を作らない）

# 文の区切り。日本語の句点/感嘆/疑問 + 英文の ! ? + 改行。区切り文字は前の文に残す（後読み）。
_SENTENCE_SPLIT = re.compile(r"(?<=[。！？!?\n])")


@dataclass
class Chunk:
    source: str
    index: int
    content: str


def normalize_text(text: str) -> str:
    """表記ゆれ最小化: 改行コード統一、行末空白除去、3行以上の空行を1つに。
    （PDF由来のテキストは空白・改行が荒れるため。ここで揃えるとチャンクの質が安定する）"""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = "\n".join(line.rstrip() for line in text.split("\n"))
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def split_sentences(text: str) -> list[str]:
    """文単位に分割。CHUNK_SIZE を超える長文（表・URL羅列など）は機械的に折る。"""
    out: list[str] = []
    for s in _SENTENCE_SPLIT.split(text):
        if not s:
            continue
        while len(s) > CHUNK_SIZE:
            out.append(s[:CHUNK_SIZE])
            s = s[CHUNK_SIZE:]
        out.append(s)
    return out


def chunk_text(text: str, source: str) -> list[Chunk]:
    """文境界を尊重しつつ CHUNK_SIZE 以内に詰め、CHUNK_OVERLAP 文字ぶんの末尾文を次チャンクに持ち越す。

    ⭐ 「文字数で機械的に切る」のではなく「文の切れ目で切る」理由:
       検索で返ってくるのはチャンク単位。文の途中で切れていると、文脈として渡された Claude が誤読するし、
       出典として画面に出した時に人間も読めない。
    """
    sentences = split_sentences(normalize_text(text))
    chunks: list[Chunk] = []
    buf: list[str] = []     # 現在組み立て中のチャンク（文のリスト）
    carried = 0             # buf 先頭のうち、前チャンクから持ち越した文の数

    def flush() -> None:
        """buf を1チャンクとして確定し、末尾 CHUNK_OVERLAP 文字ぶんの文を次の buf に残す。"""
        nonlocal buf, carried
        content = "".join(buf).strip()
        if content:
            chunks.append(Chunk(source=source, index=len(chunks), content=content))
        keep: list[str] = []
        kept = 0
        for s in reversed(buf):
            if kept >= CHUNK_OVERLAP:
                break
            keep.insert(0, s)
            kept += len(s)
        buf = keep
        carried = len(keep)

    for s in sentences:
        cur_len = sum(map(len, buf))
        if buf and cur_len + len(s) > CHUNK_SIZE:
            flush()
            # 持ち越しだけで既に上限に迫る場合（極端に長い文の連続）は持ち越しを捨てる
            if sum(map(len, buf)) + len(s) > CHUNK_SIZE:
                buf, carried = [], 0
        buf.append(s)

    # 末尾処理: 持ち越し分を除いた「新規部分」が短すぎるなら、直前チャンクに足して断片化を防ぐ
    new_part = "".join(buf[carried:]).strip()
    if chunks and new_part and len(new_part) < MIN_CHUNK_SIZE:
        chunks[-1].content += new_part
    elif new_part:
        chunks.append(Chunk(source=source, index=len(chunks), content="".join(buf).strip()))
    return chunks


# ---------------------------------------------------------------------------
# 文書の読み込み（S3 / ローカル）
# ---------------------------------------------------------------------------
SUPPORTED_EXT = {".txt", ".md", ".pdf"}


def extract_text(name: str, data: bytes) -> str:
    ext = Path(name).suffix.lower()
    if ext == ".pdf":
        from pypdf import PdfReader  # 遅延 import: PDF を扱う時だけ必要

        reader = PdfReader(io.BytesIO(data))
        return "\n".join((page.extract_text() or "") for page in reader.pages)
    # テキスト系は UTF-8 前提。BOM 付き(Windows のメモ帳保存)も utf-8-sig で吸収
    return data.decode("utf-8-sig")


def iter_local(dir_path: str):
    for p in sorted(Path(dir_path).iterdir()):
        if p.stem.upper() == "README":   # 説明ファイルは対象外（S3 へは sync --exclude で上げない）
            continue
        if p.is_file() and p.suffix.lower() in SUPPORTED_EXT:
            yield p.name, p.read_bytes()


def iter_s3(bucket: str, prefix: str):
    import boto3

    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")   # 1000件超でも取りこぼさない
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith("/") or Path(key).suffix.lower() not in SUPPORTED_EXT:
                continue
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            # source は prefix を除いたキー（出典表示用。バケット名は出さない）
            source = key[len(prefix):] if prefix and key.startswith(prefix) else key
            yield source, body


# ---------------------------------------------------------------------------
# DB 書き込み
# ---------------------------------------------------------------------------
def store(chunks: list[Chunk], vectors: list[list[float]]) -> None:
    import db
    from embeddings import to_pgvector

    source = chunks[0].source
    with db.get_conn() as conn, conn.cursor() as cur:
        # 同一 source を作り直す（冪等）。DELETE と INSERT が同じトランザクション → 途中で落ちても中途半端にならない
        cur.execute("DELETE FROM documents WHERE source = %s;", (source,))
        deleted = cur.rowcount
        cur.executemany(
            "INSERT INTO documents (source, chunk_index, content, embedding) "
            "VALUES (%s, %s, %s, %s::vector);",
            [(c.source, c.index, c.content, to_pgvector(v)) for c, v in zip(chunks, vectors)],
        )
    log.info("  stored %d chunks (replaced %d old rows)", len(chunks), deleted)


# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="S3/ローカル文書を分割・埋め込みして pgvector に格納する")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--bucket", default=os.environ.get("DOCS_BUCKET"),
                     help="文書バケット名（既定: 環境変数 DOCS_BUCKET）")
    src.add_argument("--local-dir", help="ローカルディレクトリから読む（動作確認用）")
    ap.add_argument("--prefix", default=os.environ.get("DOCS_PREFIX", ""), help="S3 キーの接頭辞")
    ap.add_argument("--dry-run", action="store_true", help="DB に書かない（分割結果と次元数を表示）")
    ap.add_argument("--skip-embed", action="store_true", help="Bedrock も呼ばない（分割だけ確認。--dry-run 時のみ）")
    ap.add_argument("--show-chunks", type=int, default=2, help="dry-run 時、各文書の先頭 N チャンクを表示")
    args = ap.parse_args()

    if args.local_dir:
        docs = iter_local(args.local_dir)
        where = f"local:{args.local_dir}"
    elif args.bucket:
        docs = iter_s3(args.bucket, args.prefix)
        where = f"s3://{args.bucket}/{args.prefix}"
    else:
        ap.error("--bucket か --local-dir を指定してください（または環境変数 DOCS_BUCKET）")

    need_embed = not (args.dry_run and args.skip_embed)
    if need_embed:
        from embeddings import embed_text

    log.info("source: %s | chunk_size=%d overlap=%d", where, CHUNK_SIZE, CHUNK_OVERLAP)
    total_docs = total_chunks = 0
    for name, data in docs:
        text = extract_text(name, data)
        chunks = chunk_text(text, source=name)
        total_docs += 1
        total_chunks += len(chunks)
        if not chunks:
            log.warning("%s: no text extracted, skipped", name)
            continue
        sizes = [len(c.content) for c in chunks]
        log.info("%s: %d chars -> %d chunks (min %d / avg %d / max %d)",
                 name, len(text), len(chunks), min(sizes), sum(sizes) // len(sizes), max(sizes))

        if args.dry_run:
            for c in chunks[: args.show_chunks]:
                log.info("  [%d] %s ...", c.index, c.content[:60].replace("\n", " "))
            if need_embed:
                vec = embed_text(chunks[0].content)   # 1文書1回だけ叩いて次元を確認（費用と時間の節約）
                log.info("  embedding dim=%d  head=%s", len(vec), [round(x, 4) for x in vec[:3]])
            continue

        vectors = [embed_text(c.content) for c in chunks]
        store(chunks, vectors)

    log.info("done: %d docs, %d chunks%s", total_docs, total_chunks,
             " (dry-run, nothing written)" if args.dry_run else "")
    if total_docs == 0:
        log.warning("no documents found (対応拡張子: %s)", ", ".join(sorted(SUPPORTED_EXT)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
