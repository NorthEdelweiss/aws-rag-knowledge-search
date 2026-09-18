variable "name_prefix" {
  type = string
}

variable "subnet_ids" {
  description = "RDS を置くプライベートサブネット（2 AZ 以上）"
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "instance_class" {
  type = string
}

variable "engine_version" {
  type = string
}

variable "allocated_storage" {
  type = number
}

variable "db_name" {
  type = string
}

variable "username" {
  type = string
}

variable "skip_final_snapshot" {
  type = bool
}

variable "secret_recovery_days" {
  type = number
}
