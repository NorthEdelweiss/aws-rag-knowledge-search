# /api/ask を PowerShell 5.1 から叩く（トラブルシュート記録 #11 クォート消失 / #12 Latin-1 文字化け の回避版）
#   使い方:  .\scripts\ask.ps1 "テレワークは週に何日まで可能ですか"
#            .\scripts\ask.ps1 "..." -TopK 3            # Top-K をリクエスト単位で変える
#            .\scripts\ask.ps1 "..." -NoRag             # 検索なし・素の生成（RAG 導入前と同じ）で比較
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Question,
    [int]$TopK = 0,
    [switch]$NoRag,
    [string]$Alb = ""   # 省略時は ..\terraform の output alb_dns_name を使う
)

if (-not $Alb) {
    $tfDir = Join-Path $PSScriptRoot "..\terraform"
    $Alb = terraform "-chdir=$tfDir" output -raw alb_dns_name 2>$null
    if (-not $Alb) { Write-Host "ALB が不明。-Alb <dns> を指定するか、terraform apply 済みの環境で実行してください" -ForegroundColor Red; exit 1 }
}

$payload = @{ question = $Question; use_rag = -not $NoRag }
if ($TopK -gt 0) { $payload.top_k = $TopK }

# body は UTF-8 の byte[] で渡す → PS 側の文字コード変換を挟まない
$json  = $payload | ConvertTo-Json -Compress
$bytes = [Text.Encoding]::UTF8.GetBytes($json)

$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-RestMethod -Method Post -Uri "http://$Alb/api/ask" `
         -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 90
} catch {
    Write-Host "HTTP error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) { Write-Host $_.ErrorDetails.Message }
    exit 1
}
$sw.Stop()

Write-Host "`n=== 回答 ($([int]$sw.Elapsed.TotalSeconds)s / tokens in=$($r.tokens.input) out=$($r.tokens.output)) ===" -ForegroundColor Cyan
Write-Host $r.answer
Write-Host "`n=== rag: used=$($r.rag.used) generated=$($r.rag.generated) top_k=$($r.rag.top_k) top_sim=$($r.rag.top_similarity) min_sim=$($r.rag.min_similarity) ===" -ForegroundColor DarkGray
if ($r.sources) {
    $r.sources | Format-Table ref, similarity, source, chunk_index, @{n = 'excerpt'; e = { $_.excerpt.Substring(0, [Math]::Min(50, $_.excerpt.Length)) } } -AutoSize
}
