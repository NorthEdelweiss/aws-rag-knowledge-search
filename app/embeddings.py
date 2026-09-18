"""
Bedrock Titan Text Embeddings v2 でテキストをベクトル化する。

⭐ なぜ独立モジュールにするか:
  取込(ingest.py)と検索(main.py の /api/ask)の **両方が同じ関数** を通ること。
  モデルID・次元数・正規化設定が片方だけ違うと、保存済みベクトルと質問ベクトルが
  「別の空間」になり、類似検索が静かに壊れる（エラーは出ない＝一番怖い）。
"""
import json
import logging
import os

import boto3
from botocore.config import Config

log = logging.getLogger("embeddings")

REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
# Titan はリージョン内モデル。Claude と違い inference profile 接頭辞(jp.)は不要（トラブルシュート記録#2参照）
EMBED_MODEL_ID = os.environ.get("BEDROCK_EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
# documents.embedding は VECTOR(1024)。ここを変えたらテーブルも作り直し＋全件再埋め込み。
EMBED_DIM = 1024

_client = boto3.client(
    "bedrock-runtime",
    region_name=REGION,
    config=Config(connect_timeout=5, read_timeout=30, retries={"max_attempts": 3, "mode": "standard"}),
)


def embed_text(text: str) -> list[float]:
    """1テキスト → 1024次元ベクトル。

    normalize=True: 長さ1に正規化して返させる。
    補足: 正規化済みなら「余弦距離 <=>」と「内積 <#>」は等価。
      pgvector で <=> を選ぶ理由は「文の長さに左右されず向きだけで比べたい」から。
    """
    body = {"inputText": text, "dimensions": EMBED_DIM, "normalize": True}
    # Titan は Converse 非対応 → InvokeModel（Converse はチャット系モデル用）
    resp = _client.invoke_model(modelId=EMBED_MODEL_ID, body=json.dumps(body))
    vec = json.loads(resp["body"].read())["embedding"]
    if len(vec) != EMBED_DIM:
        # 起きないはずだが、起きたら DB 側で INSERT が失敗するより早く・分かりやすく落とす
        raise RuntimeError(f"unexpected embedding dim: {len(vec)} (expected {EMBED_DIM})")
    return vec


def to_pgvector(vec: list[float]) -> str:
    """Python の list → pgvector のリテラル文字列 '[0.1,0.2,...]'。
    SQL 側で `%s::vector` とキャストして渡す。
    （pgvector-python + numpy を入れる手もあるが、変換1行のために依存を増やさない）"""
    return "[" + ",".join(f"{x:.7g}" for x in vec) + "]"
