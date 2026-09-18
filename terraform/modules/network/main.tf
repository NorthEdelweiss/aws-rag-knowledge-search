# ============================================================================
# network モジュール：VPC / サブネット×4 / IGW / NAT(任意) / ルートテーブル×2
#                     / セキュリティグループ×3 / S3 Gateway エンドポイント
#
# 手作業版（第1〜2週）と同じ構成を、AZ をループで生成する形に書き直したもの。
# ============================================================================

locals {
  # "ap-northeast-1a" → "1a"（Name タグ用）
  az_short = { for az in var.azs : az => substr(az, length(az) - 2, 2) }

  public_subnets  = { for i, az in var.azs : az => var.public_subnet_cidrs[i] }
  private_subnets = { for i, az in var.azs : az => var.private_subnet_cidrs[i] }
}

# ---------------------------------------------------------------------------
# VPC / IGW
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # DNS ホスト名は手作業版では OFF だったが、RDS エンドポイント名解決・
  # 将来の Interface エンドポイント（Private DNS）に必要なので ON にする
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# ---------------------------------------------------------------------------
# サブネット（public: ALB / NAT、private: ECS タスク / RDS）
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  # ALB は自分で ENI を持つので自動パブリック IP 付与は不要（手作業版と同じく OFF）
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public-${local.az_short[each.key]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name = "${var.name_prefix}-private-${local.az_short[each.key]}"
    Tier = "private"
  }
}

# ---------------------------------------------------------------------------
# ルートテーブル：public → IGW、private → NAT（NAT 有効時のみ）
#   トラブルシュート記録#6：private-rt は「誰が使うか」＝private サブネット、
#           「次のホップ」＝public サブネットにいる NAT。二つの表がリレーする。
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# NAT Gateway（enable_nat = false なら丸ごと作らない ＝「消灯」）
#   手作業版は毎晩 NAT を削除・EIP を解放し、ルートが blackhole のまま残っていた。
#   Terraform 版は count で 3 リソースを一括増減 → 消灯時に blackhole も残らない。
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count = var.enable_nat ? 1 : 0

  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat ? 1 : 0

  allocation_id     = aws_eip.nat[0].id
  subnet_id         = aws_subnet.public[var.azs[0]].id # 1 台だけ（コスト優先。可用性を取るなら AZ ごと）
  connectivity_type = "public"

  tags = { Name = "${var.name_prefix}-nat-${local.az_short[var.azs[0]]}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_default" {
  count = var.enable_nat ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

# ---------------------------------------------------------------------------
# S3 Gateway エンドポイント：ECS → S3（文書取得・ECR レイヤー取得）を NAT を通さず私設経路で
#   無料。ルートテーブルに prefix list 経路が自動追加される。
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name_prefix}-s3-gw" }
}

# ---------------------------------------------------------------------------
# セキュリティグループ：ALB(80/443←世界) → app(8000←ALB SG) → rds(5432←app SG)
#   SG 参照チェーンで「ALB を通らない経路は存在しない」を表現。CIDR を書かない。
#   ⚠️ aws_security_group はデフォルトの全許可 egress を Terraform が剥がすので
#      egress も明示する（書かないと外に出られない）。
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "ALB security group - allow web from internet"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere (listener is a later step)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "App security group - allow traffic only from ALB"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "8000 from ALB only"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.alb.id
}

# ECS タスクは Bedrock / Secrets Manager / ECR / CloudWatch Logs へ外向き通信が必要
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "allow postgres from app"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "5432 from app only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
