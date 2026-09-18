"""
ワンショットDB初期化: pgvector有効化 + documentsテーブル作成。

実行方法（プライベートサブネットのRDSには手元から届かないため）:
  ECSコンソール → クラスター rag-cluster → 「新しいタスクの実行」で
  コンテナオーバーライドのコマンドに `python,init_db.py` を指定して1回だけ実行する。
  → RDSを公開せず・踏み台も立てず、既存イメージとネットワークをそのまま再利用。

冪等（何度実行しても安全）: IF NOT EXISTS を付けてあるため。
"""
import logging

import db

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("init-db")

# ⭐ source/chunk_index を持つ理由: RAGは「出典付きで」答えられて初めて業務で信頼される。
#    どのファイルの何番目のチャンクかを保存する＝回答の根拠を提示できる。
# ⭐ VECTOR(1024): Titan Embeddings v2 の既定出力次元。256/512に落とすと
#    ストレージ・計算は軽いが精度が下がるトレードオフ（選定理由として明記）。
DDL = """
CREATE TABLE IF NOT EXISTS documents (
  id          BIGSERIAL PRIMARY KEY,
  source      TEXT NOT NULL,
  chunk_index INT  NOT NULL,
  content     TEXT NOT NULL,
  embedding   VECTOR(1024),
  created_at  TIMESTAMPTZ DEFAULT now()
);
"""
# 📝 インデックスは意図的に張らない: 数百〜数千行では順次スキャンの方が速く、
#    HNSW/IVFFlatは近似検索なので件数が少ないと精度を落とすだけ。
#    「件数が増えてからHNSWを張る」——最適化しない判断も設計のうち。


def main() -> None:
    with db.get_conn() as conn, conn.cursor() as cur:
        # CREATE EXTENSION は rds_superuser 権限が必要 → マスターユーザーならOK
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        cur.execute(DDL)

        # 結果確認（CloudWatch Logs /ecs/rag-api で見る）
        cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'vector';")
        row = cur.fetchone()
        log.info("pgvector version: %s", row[0] if row else "NOT INSTALLED")

        cur.execute(
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_name = 'documents' ORDER BY ordinal_position;"
        )
        for name, dtype in cur.fetchall():
            log.info("documents.%s : %s", name, dtype)

    log.info("init_db done.")


if __name__ == "__main__":
    main()
