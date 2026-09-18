output "vpc_id" {
  value = aws_vpc.this.id
}

# var.azs の並び順で返す（for_each の map はキー順になるので明示的に並べ直す）
output "public_subnet_ids" {
  value = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  value = [for az in var.azs : aws_subnet.private[az].id]
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "app_sg_id" {
  value = aws_security_group.app.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "nat_gateway_id" {
  value = var.enable_nat ? aws_nat_gateway.this[0].id : null
}
