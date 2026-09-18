<#
.SYNOPSIS
  ワンショットジョブ（init-db / ingest）を Fargate で 1 回走らせ、終了まで待ってログを出す。
  手作業版の「run-task + JSON overrides」を、ジョブ専用タスク定義で置き換えたもの
  （PowerShell 5.1 の JSON クォート問題＝トラブルシュート記録#11 を踏まない）。

  前提：点灯済み（NAT あり・RDS available・イメージが ECR にある）

.EXAMPLE
  .\run_job.ps1 -Job init-db
  .\run_job.ps1 -Job ingest
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('init-db', 'ingest')]
  [string]$Job
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
# aws CLI は UTF-8 で出力する。PS 5.1 の既定（ANSI）だと日本語ファイル名が文字化けする（トラブルシュート記録#12/#20）
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$cluster  = terraform output -raw ecs_cluster_name
$subnets  = (terraform output -json private_subnet_ids | ConvertFrom-Json) -join ','
$sg       = terraform output -raw app_sg_id
$family   = (terraform output -json job_task_definitions | ConvertFrom-Json).$Job
$logGroup = "/ecs/$((terraform output -raw ecs_cluster_name) -replace '-cluster$','')-api"

if ((terraform output -raw nat_enabled) -ne 'true') {
  Write-Host "NAT が無効（消灯中）。先に .\lights.ps1 on を実行" -ForegroundColor Red
  exit 1
}

Write-Host "run-task: $family on $cluster" -ForegroundColor Cyan
$taskArn = aws ecs run-task `
  --cluster $cluster `
  --launch-type FARGATE `
  --task-definition $family `
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=DISABLED}" `
  --query 'tasks[0].taskArn' --output text

if (-not $taskArn -or $taskArn -eq 'None') { Write-Host "run-task 失敗（上のエラーを確認）" -ForegroundColor Red; exit 1 }
$taskId = $taskArn.Split('/')[-1]
Write-Host "task: $taskId  （停止まで待機…）"

aws ecs wait tasks-stopped --cluster $cluster --tasks $taskArn

$info = aws ecs describe-tasks --cluster $cluster --tasks $taskArn `
  --query 'tasks[0].[stopCode,stoppedReason,containers[0].exitCode]' --output text
Write-Host "stopCode / reason / exitCode: $info"

Write-Host "`n--- logs ($logGroup / $Job/rag-job/$taskId) ---" -ForegroundColor Cyan
# --output text はイベントをタブ連結で 1 行に潰すので、JSON で受けて 1 行ずつ出す
$events = aws logs get-log-events --log-group-name $logGroup --log-stream-name "$Job/rag-job/$taskId" --output json | ConvertFrom-Json
$events.events | ForEach-Object { $_.message }
