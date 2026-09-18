variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

# --- network から ---------------------------------------------------------
variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "app_sg_id" {
  type = string
}

# --- db から --------------------------------------------------------------
variable "db_secret_arn" {
  type = string
}

# --- storage から ---------------------------------------------------------
variable "docs_bucket_name" {
  type = string
}

variable "docs_bucket_arn" {
  type = string
}

variable "docs_prefix" {
  type = string
}

# --- アプリ設定 -----------------------------------------------------------
variable "desired_count" {
  type = number
}

variable "container_image" {
  type = string
}

variable "bedrock_model_id" {
  type = string
}

variable "bedrock_profile_regions" {
  type = list(string)
}

variable "bedrock_embed_model_id" {
  type = string
}

variable "rag_top_k" {
  type = number
}

variable "rag_min_similarity" {
  type = number
}

variable "allowed_origins" {
  type = string
}

variable "log_retention_days" {
  type = number
}
