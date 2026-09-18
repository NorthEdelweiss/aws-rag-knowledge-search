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

# --- app から ------------------------------------------------------------
variable "ecr_repository_arn" {
  type = string
}

variable "ecs_service_arn" {
  type = string
}
