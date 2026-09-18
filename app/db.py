"""
RDS(PostgreSQL)への接続ヘルパー。

接続情報は環境変数から読む。値そのものはタスク定義の secrets(valueFrom) で
Secrets Manager `rag/db/credentials` の各JSONキーから注入する。
→ コードにもタスク定義の平文environmentにも、ホスト名すら書かない。
  「認証情報はどう管理していますか？」への答えがこの1ファイルで完結する。
"""
import os

import psycopg


def get_conn() -> psycopg.Connection:
    """新しいDB接続を返す。呼び出し側で `with get_conn() as conn:` で使うこと
    （withを抜ける時にcommit/close される）。

    今の規模(数千行・単一コンテナ)では接続プール無しで十分。
    補足: 「プールは？」→ トラフィックが増えたら psycopg_pool か RDS Proxy。
    最初から入れないのは、部品を増やす前に必要性を測るため。
    """
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        dbname=os.environ.get("DB_NAME", "ragdb"),
        connect_timeout=5,  # RDS停止中/SG不備の時に無限に待たない
    )
