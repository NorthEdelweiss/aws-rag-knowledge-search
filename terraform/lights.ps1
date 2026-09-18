<#
.SYNOPSIS
  RAG 環境の「点灯 / 消灯」を 1 コマンドにする。

  on     : RDS 起動 → terraform apply（NAT 作成 + API タスク 1）
  off    : terraform apply（NAT 削除 + API タスク 0）→ RDS 停止
  status : 現状確認だけ

  terraform apply は plan を表示して yes を待つ（自動承認しない。plan を読む習慣のため）。
  RDS の start/stop は Terraform に無い操作なので AWS CLI を使う。
  ⚠️ RDS は停止 7 日で自動再起動する（AWS 仕様）。長期放置なら destroy を検討。

.EXAMPLE
  .\lights.ps1 on
  .\lights.ps1 off
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('on', 'off', 'status')]
  [string]$Mode
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Get-DbId { terraform output -raw db_identifier }
function Get-DbStatus($id) {
  aws rds describe-db-instances --db-instance-identifier $id --query 'DBInstances[0].DBInstanceStatus' --output text
}

switch ($Mode) {
  'on' {
    $db = Get-DbId
    $st = Get-DbStatus $db
    if ($st -eq 'stopped') {
      Write-Host "[1/2] RDS $db を起動（数分かかる。並行して NAT を作る）" -ForegroundColor Cyan
      aws rds start-db-instance --db-instance-identifier $db --output text --query 'DBInstance.DBInstanceStatus'
    } else {
      Write-Host "[1/2] RDS $db は $st（起動操作スキップ）" -ForegroundColor Yellow
    }
    Write-Host "[2/2] terraform apply: NAT 作成 + API タスク 1" -ForegroundColor Cyan
    terraform apply -var 'enable_nat=true' -var 'app_desired_count=1'
    Write-Host "`nALB: http://$(terraform output -raw alb_dns_name)/health" -ForegroundColor Green
  }

  'off' {
    Write-Host "[1/2] terraform apply: NAT 削除 + API タスク 0" -ForegroundColor Cyan
    terraform apply -var 'enable_nat=false' -var 'app_desired_count=0'
    $db = Get-DbId
    $st = Get-DbStatus $db
    if ($st -eq 'available') {
      Write-Host "[2/2] RDS $db を停止" -ForegroundColor Cyan
      aws rds stop-db-instance --db-instance-identifier $db --output text --query 'DBInstance.DBInstanceStatus'
    } else {
      Write-Host "[2/2] RDS $db は $st（available になってから再度 off を実行）" -ForegroundColor Yellow
    }
  }

  'status' {
    $db = Get-DbId
    Write-Host "RDS  : $db = $(Get-DbStatus $db)"
    Write-Host "NAT  : enable_nat = $(terraform output -raw nat_enabled)"
    $svc = aws ecs describe-services --cluster (terraform output -raw ecs_cluster_name) --services (terraform output -raw ecs_service_name) --query 'services[0].[desiredCount,runningCount]' --output text
    Write-Host "ECS  : desired/running = $svc"
    Write-Host "ALB  : http://$(terraform output -raw alb_dns_name)"
  }
}
