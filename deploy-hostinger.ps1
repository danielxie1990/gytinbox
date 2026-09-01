# ────────────────────────────────────────────────────────────
#  gytinbox-next — Hostinger 一键部署 (共享主机 Node.js)
#
#  流程：本地 build 验证 → 打包 zip → FTP 上传 → 触发解压
#        → 清理 → 提示去 hPanel 点 Restart
#
#  前提：
#    1. FTP 凭据：复制 ftp-credentials.example.json → ftp-credentials.json 并填写
#    2. 服务器 public_html 已有 extract.php（本脚本会自动处理）
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File deploy-hostinger.ps1
# ────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"

# ═══ 配置区 ═══════════════════════════════════════════════
$ProjectDir   = $PSScriptRoot
$ZipName      = "gytinbox-deploy.zip"
$ZipPath      = Join-Path $ProjectDir $ZipName
$CredFile     = Join-Path $ProjectDir "ftp-credentials.json"
$RemoteDir    = "public_html"          # Hostinger Node.js 项目根目录
$ExtractPhp   = "extract.php"          # 服务器端解压脚本
$SiteUrl      = "https://fulimachine.com"   # 用于触发解压
# ═══════════════════════════════════════════════════════════

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "  FAIL $msg" -ForegroundColor Red }

# ─── 0. 读取 FTP 凭据 ────────────────────────────────────
if (!(Test-Path $CredFile)) {
  Write-Fail "缺少 $CredFile（请复制 ftp-credentials.example.json 并填写）"
  exit 1
}
$cred = Get-Content $CredFile -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($cred.host)) {
  Write-Fail "ftp-credentials.json 中 host 为空"
  exit 1
}
Write-OK "FTP: $($cred.host)"

# ─── 1. 本地构建验证 ─────────────────────────────────────
Write-Step "本地构建验证 (npm run build)"
Set-Location $ProjectDir
npm run build
if ($LASTEXITCODE -ne 0) { Write-Fail "构建失败，中止部署"; exit 1 }
Write-OK "构建通过"

# ─── 2. 确认 SQLite 数据库存在 ───────────────────────────
Write-Step "检查数据库文件"
$db = Join-Path $ProjectDir "prisma\dev.db"
if (!(Test-Path $db)) {
  Write-Fail "找不到 prisma\dev.db —— Hostinger 无 SSH，必须本地建库后随包上传！"
  Write-Host "  请先运行: npm run db:reset 或 npx prisma db push && npx tsx prisma/seed.ts"
  exit 1
}
Write-OK "prisma/dev.db ($([math]::Round((Get-Item $db).Length/1MB,1)) MB)"

# ─── 3. 打包（排除 node_modules / .next / .git / 旧包） ──
Write-Step "打包源码"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
$items = @(
  "app", "components", "lib", "prisma", "public", "types", "updates", "data",
  "package.json", "package-lock.json", "next.config.js", "tsconfig.json",
  "postcss.config.js", "tailwind.config.js", "middleware.ts",
  ".env", ".env.example"
) | Where-Object { Test-Path (Join-Path $ProjectDir $_) }
tar -a -c -f $ZipPath -C $ProjectDir $items
if (!(Test-Path $ZipPath)) { Write-Fail "打包失败"; exit 1 }
Write-OK "$ZipName ($([math]::Round((Get-Item $ZipPath).Length/1MB,1)) MB)"

# ─── 4. FTP 上传 ─────────────────────────────────────────
Write-Step "FTP 上传"
$ftpBase = "ftp://$($cred.host)/$RemoteDir"
$webClient = New-Object System.Net.WebClient
$webClient.Credentials = New-Object System.Net.NetworkCredential($cred.user, $cred.pass)

# 4a. 上传 zip
$webClient.UploadFile("$ftpBase/$ZipName", "STOR", $ZipPath)
Write-OK "上传 $ZipName"

# 4b. 上传解压脚本（若服务器已有则覆盖，保证最新）
$extractLocal = Join-Path $ProjectDir $ExtractPhp
if (!(Test-Path $extractLocal)) {
  @'
<?php
$zip = new ZipArchive;
$res = $zip->open('gytinbox-deploy.zip');
if ($res === TRUE) {
  $zip->extractTo('.');
  $zip->close();
  echo 'Extracted successfully. Delete this file now.';
} else {
  echo 'Failed to extract.';
}
'@ | Set-Content $extractLocal -Encoding UTF8
}
$webClient.UploadFile("$ftpBase/$ExtractPhp", "STOR", $extractLocal)
Write-OK "上传 $ExtractPhp"

$webClient.Dispose()

# ─── 5. 触发解压 ────────────────────────────────────────
Write-Step "服务器端解压"
try {
  $resp = (Invoke-WebRequest -Uri "$SiteUrl/$ExtractPhp" -UseBasicParsing -TimeoutSec 60).Content
  if ($resp -match "Extracted") { Write-OK "解压成功" }
  else { Write-Fail "解压结果异常: $resp" }
} catch {
  Write-Fail "触发解压失败: $($_.Exception.Message)"
  Write-Host "  请手动访问: $SiteUrl/$ExtractPhp"
}

# ─── 6. 删除解压脚本（安全） ─────────────────────────────
Write-Step "清理解压脚本"
try {
  $delClient = New-Object System.Net.WebClient
  $delClient.Credentials = New-Object System.Net.NetworkCredential($cred.user, $cred.pass)
  $delClient.UploadFile("$ftpBase/$ExtractPhp", "DELE", $extractLocal)
  $delClient.Dispose()
  Write-OK "已删除服务器上的 $ExtractPhp"
} catch {
  Write-Fail "删除 $ExtractPhp 失败（请手动在文件管理器删除，避免安全风险）"
}

Write-Host ""
Write-Host "══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  上传完成！最后一步（必须手动）：" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. 打开 Hostinger hPanel → 网站 → Node.js"
Write-Host "  2. 点击「Restart」（自动执行 npm install + build）"
Write-Host "  3. 等 1-3 分钟后访问: $SiteUrl"
Write-Host ""
Write-Host "  ⚠️  如果页面还是旧的/503：再点一次 Restart"
Write-Host "══════════════════════════════════════════════════" -ForegroundColor Cyan
