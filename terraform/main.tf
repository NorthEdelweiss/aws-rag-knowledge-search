# ============================================================================
# ルート：4 モジュールを配線する。
#   network → (subnet / SG) → db, app
#   storage → (bucket ARN) → app（IAM）
#   db      → (secret ARN) → app（タスク定義 secrets）
#
#   設計ポイント：モジュール間は「出力→入力」でしか繋がない（ID をベタ書きしない）。
#   network を差し替えても app のコードは 1 行も変わらない。
# ============================================================================

module "network" {
  source = "./modules/network"

  name_prefix          = var.name_prefix
  region               = var.region
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat           = var.enable_nat
}

module "storage" {
  source = "./modules/storage"

  bucket_name = var.docs_bucket_name
}

module "db" {
  source = "./modules/db"

  name_prefix          = var.name_prefix
  subnet_ids           = module.network.private_subnet_ids
  security_group_id    = module.network.rds_sg_id
  instance_class       = var.db_instance_class
  engine_version       = var.db_engine_version
  allocated_storage    = var.db_allocated_storage
  db_name              = var.db_name
  username             = var.db_username
  skip_final_snapshot  = var.db_skip_final_snapshot
  secret_recovery_days = var.db_secret_recovery_window_days
}

module "app" {
  source = "./modules/app"

  name_prefix        = var.name_prefix
  region             = var.region
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  alb_sg_id          = module.network.alb_sg_id
  app_sg_id          = module.network.app_sg_id

  db_secret_arn = module.db.secret_arn

  docs_bucket_name = module.storage.bucket_name
  docs_bucket_arn  = module.storage.bucket_arn
  docs_prefix      = var.docs_prefix

  desired_count           = var.app_desired_count
  container_image         = var.container_image
  bedrock_model_id        = var.bedrock_model_id
  bedrock_profile_regions = var.bedrock_profile_regions
  bedrock_embed_model_id  = var.bedrock_embed_model_id
  rag_top_k               = var.rag_top_k
  rag_min_similarity      = var.rag_min_similarity
  allowed_origins         = var.allowed_origins
  log_retention_days      = var.log_retention_days
}

# CI/CD（GitHub Actions が OIDC で引き受ける deploy ロール）。
# github_repository が空なら作らない（CI を使わない環境でも同じコードが動く）。
module "cicd" {
  count  = var.github_repository != "" ? 1 : 0
  source = "./modules/cicd"

  name_prefix          = var.name_prefix
  github_repository    = var.github_repository
  github_branch        = var.github_branch
  github_owner_id      = var.github_owner_id
  github_repository_id = var.github_repository_id
  ecr_repository_arn   = module.app.ecr_repository_arn
  ecs_service_arn      = module.app.service_arn
}
