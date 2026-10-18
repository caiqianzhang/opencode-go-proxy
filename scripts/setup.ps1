# OpenCode Go proxy setup for Codex on Windows.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
# or:
#   irm https://raw.githubusercontent.com/caiqianzhang/opencode-go-proxy/main/scripts/setup.ps1 | iex

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
$ModelSlug = 'deepseek-v4.1-flash'
$ProviderId = 'opencode-go'
$DefaultRemoteBaseUrl = ''
$CodexHomeDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$ConfigPath = Join-Path $CodexHomeDir 'config.toml'
$BackupRoot = Join-Path $CodexHomeDir 'backup-opencode-go-proxy'

$BundledCatalogJson = @'
{
  "models": [
    {
      "slug": "deepseek-v4.1-flash",
      "prefer_websockets": false,
      "support_verbosity": true,
      "default_verbosity": "low",
      "apply_patch_tool_type": "freeform",
      "web_search_tool_type": "text",
      "input_modalities": ["text", "image"],
      "supports_image_detail_original": true,
      "truncation_policy": {"mode": "tokens", "limit": 10000},
      "supports_parallel_tool_calls": true,
      "tool_mode": null,
      "multi_agent_version": "v2",
      "use_responses_lite": false,
      "include_skills_usage_instructions": false,
      "auto_review_model_override": null,
      "context_window": 1048576,
      "max_context_window": 1048576,
      "effective_context_window_percent": 95,
      "auto_compact_token_limit": null,
      "comp_hash": "3000",
      "reasoning_summary_format": "experimental",
      "default_reasoning_summary": "none",
      "display_name": "deepseek-v4.1-flash",
      "description": "Local New API model (metadata: default)",
      "default_reasoning_level": "high",
      "supported_reasoning_levels": [
        {"effort": "low", "description": "Fast responses with lighter reasoning"},
        {"effort": "high", "description": "Extra high reasoning depth for complex problems"},
        {"effort": "max", "description": "Maximum reasoning depth for the hardest problems"}
      ],
      "shell_type": "shell_command",
      "visibility": "list",
      "minimal_client_version": "0.144.0",
      "supported_in_api": true,
      "availability_nux": null,
      "upgrade": null,
      "priority": 1,
      "experimental_supported_tools": [],
      "supports_search_tool": true,
      "default_service_tier": null,
      "supports_reasoning_summaries": true,
      "model_messages": {
        "instructions_template": "You are Codex, an AI coding agent. Follow the user instructions and use the provided tools carefully."
      }
    }
  ]
}
'@

function Write-Ok { param($Message) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn2 { param($Message) Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Head { param($Message) Write-Host ''; Write-Host $Message -ForegroundColor White }
function Die { param($Message) Write-Host "[X] $Message" -ForegroundColor Red; throw $Message }

$Mode = $env:SETUP_MODE
$BaseUrl = if ($env:SETUP_BASE_URL) { $env:SETUP_BASE_URL } else { $DefaultRemoteBaseUrl }
$Token = $env:PROXY_CLIENT_TOKEN
$Catalog = $env:SETUP_CATALOG
$CaCert = $env:PROXY_CA_CERT
$InstallCatalog = ($env:SETUP_INSTALL_CATALOG -eq '1')
$Yes = ($env:SETUP_YES -eq '1')
$SkipTest = ($env:SETUP_SKIP_TEST -eq '1')

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        '--mode' { if ($i + 1 -ge $args.Count) { Die '--mode requires a value' }; $Mode = $args[$i + 1]; $i++ }
        '--base-url' { if ($i + 1 -ge $args.Count) { Die '--base-url requires a value' }; $BaseUrl = $args[$i + 1]; $i++ }
        '--token' { if ($i + 1 -ge $args.Count) { Die '--token requires a value' }; $Token = $args[$i + 1]; $i++ }
        '--catalog' { if ($i + 1 -ge $args.Count) { Die '--catalog requires a value' }; $Catalog = $args[$i + 1]; $i++ }
        '--ca-cert' { if ($i + 1 -ge $args.Count) { Die '--ca-cert requires a value' }; $CaCert = $args[$i + 1]; $i++ }
        '--install-catalog' { $InstallCatalog = $true }
        '--yes' { $Yes = $true }
        '--skip-test' { $SkipTest = $true }
        '-h' { Write-Host 'Usage: setup.ps1 [--mode remote|restore] [--base-url URL] [--token TOKEN] [--catalog PATH] [--ca-cert PATH] [--install-catalog] [--yes] [--skip-test]'; return }
        '--help' { Write-Host 'Usage: setup.ps1 [--mode remote|restore] [--base-url URL] [--token TOKEN] [--catalog PATH] [--ca-cert PATH] [--install-catalog] [--yes] [--skip-test]'; return }
        default { Die "Unknown argument: $($args[$i])" }
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Resolve-Catalog {
    param([bool]$Force)
    $bundled = Join-Path $CodexHomeDir 'models.opencode-go.json'
    if (-not $Force) {
        foreach ($name in @('models.newapi.json', 'models.json')) {
            $candidate = Join-Path $CodexHomeDir $name
            if (Test-Path $candidate) { return $candidate }
        }
        if (Test-Path $bundled) { return $bundled }
    }
    New-Item -ItemType Directory -Path $CodexHomeDir -Force | Out-Null
    if (Test-Path $bundled) {
        Copy-Item -LiteralPath $bundled -Destination "$bundled.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
    }
    Write-Utf8NoBom $bundled $BundledCatalogJson
    return $bundled
}

function Backup-Config {
    param([string]$Mode, [string]$BaseUrl)
    if (-not (Test-Path $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    $originalDir = Join-Path $BackupRoot 'original'
    if (Test-Path $originalDir) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dir = Join-Path $BackupRoot "snapshot-$stamp-$PID"
    } else {
        $dir = $originalDir
    }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $existed = 1
    if (Test-Path $ConfigPath) {
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $dir 'config.toml') -Force
    } else {
        $existed = 0
    }
    Write-Utf8NoBom (Join-Path $dir 'manifest.txt') @"
script_version=$ScriptVersion
installed_at=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
mode=$Mode
base_url=$BaseUrl
original_config_existed=$existed
"@
    Write-Ok "已备份 Codex 配置 -> $dir"
}

function Set-TopLevelKey {
    param([string[]]$Lines, [string]$Key, [string]$Value)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $found = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ($line -match $pattern) {
            if (-not $found) {
                $out.Add("$Key = $Value")
                $found = $true
            }
        } else {
            $out.Add($line)
        }
    }
    if (-not $found) {
        $idx = $out.Count
        while ($idx -gt 0 -and $out[$idx - 1].Trim() -eq '') { $idx-- }
        $out.Insert($idx, "$Key = $Value")
    }
    return ,$out.ToArray()
}

function Update-Config {
    param([string]$BaseUrl, [string]$ClientToken, [string]$CatalogPath)
    $text = if (Test-Path $ConfigPath) { Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 } else { '' }
    $lines = if ($text.Length -gt 0) { $text -split "`r?`n" } else { @() }

    $kept = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $header = $Matches[1].Trim()
            $skip = ($header -eq "model_providers.$ProviderId") -or $header.StartsWith("model_providers.$ProviderId.")
        }
        if (-not $skip) { $kept.Add($line) }
    }
    $lines = $kept.ToArray()

    $firstSection = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('[')) { $firstSection = $i; break }
    }
    $head = if ($firstSection -gt 0) { $lines[0..($firstSection - 1)] } else { @() }
    $tail = if ($firstSection -lt $lines.Count) { $lines[$firstSection..($lines.Count - 1)] } else { @() }

    $head = Set-TopLevelKey $head 'model' (ConvertTo-Json $ModelSlug -Compress)
    $head = Set-TopLevelKey $head 'model_provider' (ConvertTo-Json $ProviderId -Compress)
    if ($CatalogPath) {
        $head = Set-TopLevelKey $head 'model_catalog_json' (ConvertTo-Json $CatalogPath -Compress)
    }

    $block = @(
        '',
        "[model_providers.$ProviderId]",
        'name = "OpenCode Go"',
        "base_url = $(ConvertTo-Json $BaseUrl -Compress)",
        'wire_api = "responses"',
        "experimental_bearer_token = $(ConvertTo-Json $ClientToken -Compress)"
    )
    $newText = ((@($head) + @($tail) + $block) -join "`n").TrimEnd() + "`n"

    if ($newText -notmatch "(?m)^\[model_providers\.$([regex]::Escape($ProviderId))\]$") {
        Die '生成的 config.toml 缺少 provider 块，已中止。'
    }
    New-Item -ItemType Directory -Path (Split-Path $ConfigPath) -Force | Out-Null
    Write-Utf8NoBom $ConfigPath $newText
    Write-Ok "已更新 $ConfigPath"
    if ($newText -match '(?m)^\s*profile\s*=') {
        Write-Warn2 '检测到顶层 profile，可能覆盖 model/model_provider；请检查 profile 内容。'
    }
    if ($newText -notmatch '(?m)^\s*model_catalog_json\s*=') {
        Write-Warn2 '未设置 model_catalog_json；若 Codex 显示 fallback/Unknown model，请用 --catalog 指定模型目录。'
    }
}

function Install-CaCert {
    param([string]$Path)
    if (-not $Path) { return }
    if (-not (Test-Path $Path)) { Die "CA certificate not found: $Path" }
    & certutil.exe -addstore -user Root $Path | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "证书导入失败。请手动导入 $Path 到当前用户的受信任根证书。"
    } else {
        Write-Ok "CA 证书已导入当前用户的受信任根证书"
    }
}

function Test-Remote {
    param([string]$BaseUrl, [string]$ClientToken)
    $code = 0
    try {
        $resp = Invoke-WebRequest -Uri "$BaseUrl/responses" -Method Post `
            -Headers @{ Authorization = "Bearer $ClientToken" } `
            -ContentType 'application/json' -Body '{}' -UseBasicParsing
        $code = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
        }
    }
    if ($code -eq 401 -or $code -eq 403) {
        Die "远端拒绝了这个 client token（HTTP $code）。"
    } elseif ($code -eq 0) {
        Write-Warn2 "远端连通性检查失败；请确认网络和 IP 证书。"
    } elseif ($code -ge 200 -and $code -lt 600) {
        Write-Ok "远端鉴权通过（HTTP $code，空探测请求被上游拒绝属正常）"
    } else {
        Write-Warn2 "远端返回了未预期的 HTTP $code"
    }
}

function Restore-Config {
    if (-not (Test-Path $BackupRoot)) { Die "没有找到备份目录：$BackupRoot" }
    $items = New-Object System.Collections.Generic.List[string]
    $original = Join-Path $BackupRoot 'original'
    if (Test-Path $original) { $items.Add('original') }
    Get-ChildItem -LiteralPath $BackupRoot -Directory |
        Where-Object { $_.Name -like 'snapshot-*' } |
        Sort-Object Name -Descending |
        ForEach-Object { $items.Add($_.Name) }
    if ($items.Count -eq 0) { Die '没有可恢复的备份。' }

    $chosen = $items[0]
    if (-not $Yes -and $items.Count -gt 1) {
        Write-Head '选择要恢复的备份'
        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-Host "  $($i + 1). $($items[$i])"
        }
        $answer = Read-Host '输入序号（默认 1）'
        if (-not $answer) { $answer = '1' }
        $idx = [int]$answer - 1
        if ($idx -lt 0 -or $idx -ge $items.Count) { Die '序号超出范围。' }
        $chosen = $items[$idx]
    }

    $dir = Join-Path $BackupRoot $chosen
    $manifest = Join-Path $dir 'manifest.txt'
    $existed = '1'
    if (Test-Path $manifest) {
        $line = Get-Content -LiteralPath $manifest | Where-Object { $_ -like 'original_config_existed=*' } | Select-Object -First 1
        if ($line) { $existed = $line.Substring($line.IndexOf('=') + 1) }
    }
    if (-not $Yes) {
        $answer = Read-Host "确认恢复 $chosen？输入 y 继续"
        if ($answer -notin @('y', 'Y', 'yes', 'YES')) { Write-Host '已取消。'; return }
    }

    if ($existed -eq '0') {
        if (Test-Path $ConfigPath) { Remove-Item -LiteralPath $ConfigPath -Force }
        Write-Ok '已删除安装时新建的 config.toml'
    } else {
        $backupConfig = Join-Path $dir 'config.toml'
        if (-not (Test-Path $backupConfig)) { Die "备份损坏：缺少 $backupConfig" }
        Copy-Item -LiteralPath $backupConfig -Destination $ConfigPath -Force
        Write-Ok "已恢复 $ConfigPath"
    }
    Write-Host "备份保留在 $dir"
}

if (-not $Mode) {
    Write-Head 'OpenCode Go x Codex 配置'
    Write-Host '  1. 使用远端代理（推荐）'
    Write-Host '  9. 恢复最近一次备份'
    $choice = Read-Host '输入 1 / 9'
    switch ($choice) {
        '1' { $Mode = 'remote' }
        '9' { $Mode = 'restore' }
        default { Die '无效选择。' }
    }
}

if ($Mode -eq 'restore') {
    Restore-Config
    return
}
if ($Mode -ne 'remote') {
    Die "Windows 脚本目前支持 remote/restore；local 模式请使用 Linux/WSL。"
}

if (-not $BaseUrl) {
    $BaseUrl = Read-Host '请输入远端 proxy base URL（例如 https://your-host:9876/codex/v1）'
}
if (-not $BaseUrl) { Die 'base URL 不能为空。' }

if (-not $Token) {
    $secure = Read-Host '请输入 remote client token' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}
if (-not $Token) { Die 'token 不能为空。' }

Install-CaCert $CaCert
if (-not $SkipTest) { Test-Remote $BaseUrl $Token }
if (-not $Catalog) {
    $Catalog = Resolve-Catalog $InstallCatalog
}
Backup-Config 'remote' $BaseUrl
Update-Config $BaseUrl $Token $Catalog

Write-Head '完成'
Write-Host "  model          = $ModelSlug"
Write-Host "  model_provider = $ProviderId"
Write-Host "  base_url       = $BaseUrl"
Write-Host ''
Write-Warn2 '请完全退出并重启 Codex，配置才会生效。'
