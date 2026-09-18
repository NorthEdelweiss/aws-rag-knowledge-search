# slim = 軽量なPythonイメージでコンテナサイズとPull時間を削減
FROM python:3.12-slim

# 作業ディレクトリ
WORKDIR /app

# 依存だけ先にコピー→インストール（レイヤーキャッシュが効き、コード変更時の再ビルドが速い）
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# アプリ本体。init_db.py / ingest.py はワンショットタスク用（run-task のコマンド上書きで実行）。
# 同じイメージに同梱する＝取込ジョブ専用の別イメージ・別パイプラインを持たない（部品を増やさない）
COPY main.py db.py embeddings.py rag.py init_db.py ingest.py ./

# ⭐ 非rootユーザーで実行する
#    コンテナがroot実行だと、万一侵入された際にコンテナ内で何でもできてしまう。
#    セキュリティレビューで最も指摘される項目のひとつ。。
RUN useradd --create-home --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app
USER appuser

# コンテナが待ち受けるポート（ドキュメント目的。実際の公開はECS/ALB側で行う）
EXPOSE 8000

# uvicornで起動。0.0.0.0=コンテナ外からの接続を受ける（127.0.0.1だとALBから届かない）
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
