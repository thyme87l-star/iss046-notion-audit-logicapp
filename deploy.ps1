<#
.SYNOPSIS
    ISS-046 Notion Audit Log → Sentinel: Logic App (Consumption) 自動展開スクリプト

.DESCRIPTION
    params.json に記入されたパラメータを読み取り、以下を自動実行します:
      Step 0: Azure CLI ログイン
      Step 1: リソースグループの作成
      Step 2: Bicep でインフラをデプロイ (DCE + DCR)
      Step 3: Logic App (Consumption) のデプロイ
      Step 4: RBAC 割り当て (Monitoring Metrics Publisher)
      Step 5: Logic App の有効化
      Step 6: 動作確認

.PARAMETER ParamsFile
    パラメータファイルのパス（デフォルト: 同フォルダの params.json）

.PARAMETER SkipLogin
    Azure CLI ログイン済みの場合はこのスイッチを指定

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -ParamsFile .\my-params.json
    .\deploy.ps1 -SkipLogin
#>

[CmdletBinding()]
param(
    [string]$ParamsFile = "$PSScriptRoot\params.json",
    [switch]$SkipLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# ユーティリティ関数
# ============================================================
function Write-Step {
    param([string]$StepNum, [string]$Title)
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "  Step $StepNum: $Title" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
}

function Write-Check {
    param([string]$Message)
    Write-Host "  [CHECK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN]  $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL]  $Message" -ForegroundColor Red
}

function Confirm-Continue {
    param([string]$Message)
    $response = Read-Host "$Message (y/N)"
    if ($response -ne 'y' -and $response -ne 'Y') {
        Write-Host "中断しました。" -ForegroundColor Yellow
        exit 0
    }
}

# ============================================================
# パラメータ読み込みとバリデーション
# ============================================================
Write-Host ""
Write-Host "ISS-046 Notion Audit Log -> Sentinel: Logic App (Consumption) 展開スクリプト" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host ""

if (-not (Test-Path $ParamsFile)) {
    Write-Fail "パラメータファイルが見つかりません: $ParamsFile"
    Write-Host "  params.json を編集してから再実行してください。"
    exit 1
}

Write-Host "パラメータファイル: $ParamsFile" -ForegroundColor Gray
$config = Get-Content $ParamsFile -Raw | ConvertFrom-Json

# 必須パラメータの検証
$errors = @()
if ([string]::IsNullOrWhiteSpace($config.azure.subscriptionId)) {
    $errors += "azure.subscriptionId が未設定です"
}
if ([string]::IsNullOrWhiteSpace($config.sentinel.workspaceResourceId) -or
    $config.sentinel.workspaceResourceId -match '<SUB_ID>') {
    $errors += "sentinel.workspaceResourceId が未設定またはプレースホルダのままです"
}
if ([string]::IsNullOrWhiteSpace($config.notion.integrationToken)) {
    $errors += "notion.integrationToken が未設定です"
}

if ($errors.Count -gt 0) {
    Write-Fail "パラメータエラー:"
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "params.json を編集してから再実行してください。"
    exit 1
}

# パラメータの展開
$subscriptionId     = $config.azure.subscriptionId
$rgName             = $config.azure.resourceGroupName
$location           = $config.azure.location
$workspaceResId     = $config.sentinel.workspaceResourceId
$notionToken        = $config.notion.integrationToken
$baseName           = $config.options.baseName
$logicAppName       = $baseName
$notionApiBaseUrl   = if ($config.notion.PSObject.Properties['apiBaseUrl'] -and
                          -not [string]::IsNullOrWhiteSpace($config.notion.apiBaseUrl)) {
                          $config.notion.apiBaseUrl
                      } else { 'https://api.notion.com' }

Write-Host ""
Write-Host "--- 展開パラメータ確認 ---" -ForegroundColor White
Write-Host "  サブスクリプション ID : $subscriptionId"
Write-Host "  リソースグループ     : $rgName"
Write-Host "  リージョン           : $location"
Write-Host "  Sentinel WS          : $workspaceResId"
Write-Host "  Notion Token         : $('*' * 8)...(非表示)"
Write-Host "  Notion API Base URL  : $notionApiBaseUrl"
Write-Host "  ベース名             : $baseName"
Write-Host "  Logic App 名         : $logicAppName"
Write-Host ""
Confirm-Continue "上記の内容で展開を開始しますか？"

# ============================================================
# Step 0: Azure CLI ログイン
# ============================================================
if (-not $SkipLogin) {
    Write-Step "0" "Azure CLI ログイン"

    # Azure CLI バージョン確認
    try {
        $azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
        Write-Check "Azure CLI バージョン: $azVersion"
    } catch {
        Write-Fail "Azure CLI がインストールされていません。"
        Write-Host "  インストール: https://learn.microsoft.com/ja-jp/cli/azure/install-azure-cli"
        exit 1
    }

    Write-Host "  Azure にログインします..."
    az login 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Azure CLI ログインに失敗しました"
        exit 1
    }
    Write-Check "ログイン成功"

    # サブスクリプション設定
    az account set --subscription $subscriptionId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "サブスクリプション $subscriptionId の設定に失敗しました"
        Write-Host "  サブスクリプション ID を確認してください。"
        exit 1
    }
    $accountName = az account show --query name -o tsv
    Write-Check "サブスクリプション: $accountName ($subscriptionId)"
} else {
    Write-Host "  Azure CLI ログインをスキップしました (-SkipLogin)" -ForegroundColor Gray
}

# ============================================================
# Step 1: リソースグループの作成
# ============================================================
Write-Step "1" "リソースグループの作成"

$rgExists = az group exists --name $rgName 2>$null
if ($rgExists -eq 'true') {
    Write-Warn "リソースグループ '$rgName' は既に存在します。既存のリソースグループを使用します。"
} else {
    Write-Host "  リソースグループ '$rgName' を '$location' に作成します..."
    az group create --name $rgName --location $location -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "リソースグループの作成に失敗しました"
        exit 1
    }
}

$rgState = az group show --name $rgName --query properties.provisioningState -o tsv
Write-Check "リソースグループ: $rgName ($location) — $rgState"

# ============================================================
# Step 2: Bicep でインフラをデプロイ (DCE + DCR)
# ============================================================
Write-Step "2" "Bicep でインフラをデプロイ (DCE + DCR)"

$bicepFile = "$PSScriptRoot\ISS-046_deploy.bicep"
if (-not (Test-Path $bicepFile)) {
    Write-Fail "Bicep ファイルが見つかりません: $bicepFile"
    exit 1
}

Write-Host "  Bicep テンプレートをデプロイ中..."
Write-Host "  （数分かかる場合があります）" -ForegroundColor Gray

$deployOutput = az deployment group create `
    --resource-group $rgName `
    --template-file $bicepFile `
    --parameters `
        sentinelWorkspaceResourceId=$workspaceResId `
        baseName=$baseName `
    --query properties.outputs -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Bicep デプロイに失敗しました"
    Write-Host $deployOutput
    exit 1
}

$outputs = $deployOutput | ConvertFrom-Json
$dceEndpoint     = $outputs.dceEndpoint.value
$dcrImmutableId  = $outputs.dcrImmutableId.value
$dcrResourceId   = $outputs.dcrResourceId.value

Write-Check "インフラデプロイ完了"
Write-Host "  DCE Endpoint   : $dceEndpoint"
Write-Host "  DCR Immutable ID: $dcrImmutableId"

# ============================================================
# Step 3: Logic App (Consumption) のデプロイ
# ============================================================
Write-Step "3" "Logic App (Consumption) のデプロイ"

$consumptionTemplate = "$PSScriptRoot\ISS-046_logic_app_consumption.json"
if (-not (Test-Path $consumptionTemplate)) {
    Write-Fail "Consumption テンプレートが見つかりません: $consumptionTemplate"
    exit 1
}

Write-Host "  Consumption Logic App をデプロイ中..."
$laDeployOutput = az deployment group create `
    --resource-group $rgName `
    --template-file $consumptionTemplate `
    --parameters `
        logicAppName=$logicAppName `
        notionApiBaseUrl=$notionApiBaseUrl `
        notionToken=$notionToken `
        dceEndpoint=$dceEndpoint `
        dcrImmutableId=$dcrImmutableId `
    --query properties.outputs -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Logic App のデプロイに失敗しました"
    Write-Host $laDeployOutput
    exit 1
}

$laOutputs = $laDeployOutput | ConvertFrom-Json
$laPrincipalId = $laOutputs.logicAppPrincipalId.value

Write-Check "Logic App デプロイ完了"
Write-Host "  Logic App 名    : $logicAppName (状態: Disabled)"
Write-Host "  MSI Principal ID: $laPrincipalId"

# ============================================================
# Step 4: RBAC 割り当て (Monitoring Metrics Publisher → DCR)
# ============================================================
Write-Step "4" "RBAC 割り当て"

Write-Host "  Logic App MSI に Monitoring Metrics Publisher ロールを割り当て中..."

# Monitoring Metrics Publisher role ID: 3913510d-42f4-4e42-8a64-420c390055eb
az role assignment create `
    --assignee-object-id $laPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "3913510d-42f4-4e42-8a64-420c390055eb" `
    --scope $dcrResourceId `
    -o none 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Fail "RBAC 割り当てに失敗しました"
    exit 1
}

Write-Check "Monitoring Metrics Publisher ロールを DCR に割り当て完了"
Write-Host "  RBAC の反映に最大 5 分かかる場合があります" -ForegroundColor Gray

# ============================================================
# Step 5: Logic App の有効化
# ============================================================
Write-Step "5" "Logic App の有効化"

Write-Host "  Logic App '$logicAppName' を有効化します..."
$enableUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Logic/workflows/$logicAppName/enable?api-version=2019-05-01"
az rest --method post --url $enableUrl 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Logic App の有効化に失敗しました"
    exit 1
}

$laState = az rest --method get `
    --url "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Logic/workflows/$logicAppName`?api-version=2019-05-01" `
    --query properties.state -o tsv
Write-Check "Logic App 状態: $laState"

# ============================================================
# Step 6: 動作確認
# ============================================================
Write-Step "6" "動作確認"

Write-Host "  Logic App の初回実行を待機中（最大 5 分）..."
Write-Host "  Recurrence トリガー（1 時間間隔）が起動するのを待っています..." -ForegroundColor Gray
Write-Host "  ※ 即時テストする場合は Azure Portal から手動トリガーしてください" -ForegroundColor Gray

$maxWait = 300  # 5 minutes
$waited = 0
$interval = 15

while ($waited -lt $maxWait) {
    Start-Sleep -Seconds $interval
    $waited += $interval

    $runsJson = az rest --method get `
        --url "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Logic/workflows/$logicAppName/runs?api-version=2019-05-01&`$top=1" `
        --query "value[0].properties.status" -o tsv 2>$null

    if ($runsJson -eq "Succeeded") {
        Write-Check "Logic App の初回実行が成功しました"
        break
    } elseif ($runsJson -eq "Failed") {
        Write-Warn "Logic App の初回実行が失敗しました。トラブルシューティングを参照してください。"
        break
    }

    Write-Host "  ... 待機中 ($waited 秒 / $maxWait 秒)" -ForegroundColor Gray
}

if ($waited -ge $maxWait) {
    Write-Warn "タイムアウト: Logic App の実行がまだ開始されていません。"
    Write-Host "  Recurrence トリガーは 1 時間間隔です。" -ForegroundColor Gray
    Write-Host "  Azure Portal → Logic App → トリガーの実行 で手動実行できます。" -ForegroundColor Gray
}

# ============================================================
# 完了サマリー
# ============================================================
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Green
Write-Host "  展開完了" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Green
Write-Host ""
Write-Host "  リソースグループ  : $rgName"
Write-Host "  Logic App         : $logicAppName (状態: $laState)"
Write-Host "  DCE Endpoint      : $dceEndpoint"
Write-Host "  DCR Immutable ID  : $dcrImmutableId"
Write-Host ""
Write-Host "  デプロイされたリソース:" -ForegroundColor White
Write-Host "    - Data Collection Endpoint (DCE)"
Write-Host "    - Data Collection Rule (DCR)"
Write-Host "    - Logic App (Consumption) — Notion API → DCE 連携"
Write-Host ""
Write-Host "  データ確認 (KQL):" -ForegroundColor White
Write-Host "    Defender ポータル → Advanced Hunting で以下を実行:"
Write-Host "    NotionAuditLog_CL | where TimeGenerated > ago(1h) | count"
Write-Host ""
Write-Host "  ※ データがテーブルに表示されるまで最大 10 分の遅延があります。"
Write-Host ""
