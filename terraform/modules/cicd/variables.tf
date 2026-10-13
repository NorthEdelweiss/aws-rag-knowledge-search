variable "name_prefix" {
  type = string
}

variable "github_repository" {
  description = "AssumeRole を許可する GitHub リポジトリ（owner/repo）"
  type        = string
}

variable "github_branch" {
  description = "AssumeRole を許可するブランチ（refs/heads/<branch>）"
  type        = string
}

variable "github_owner_id" {
  description = "GitHub のオーナー（ユーザー/組織）の数値 ID。空なら sub に ID を含めない旧形式"
  type        = string
  default     = ""
}

variable "github_repository_id" {
  description = "GitHub リポジトリの数値 ID。github_owner_id とセットで指定する"
  type        = string
  default     = ""
}

# --- app から ------------------------------------------------------------
variable "ecr_repository_arn" {
  type = string
}

variable "ecs_service_arn" {
  type = string
}
