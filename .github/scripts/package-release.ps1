[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VersionTag = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "build/release-assets"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ── 路径 ────────────────────────────────────────────────────────────────
# $PSScriptRoot = <repo>\.github\scripts
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$versionFile = Join-Path $repoRoot "VERSION"
$gameVersionFile = Join-Path $repoRoot "GAMEVERSION"

foreach ($f in @($versionFile, $gameVersionFile)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "缺少版本文件：'$f'" }
}

$modVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
$gameVersion = (Get-Content -LiteralPath $gameVersionFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($modVersion)) { throw "VERSION 为空" }
if ([string]::IsNullOrWhiteSpace($gameVersion)) { throw "GAMEVERSION 为空" }

if ([string]::IsNullOrWhiteSpace($VersionTag)) { $VersionTag = "v$modVersion" }

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "build/release-assets"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $repoRoot $OutputDir
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

$failures = [System.Collections.Generic.List[string]]::new()

function Write-Section([string]$title) {
    Write-Host ""
    Write-Host "── $title " -ForegroundColor Cyan -NoNewline
    Write-Host ("─" * [Math]::Max(0, 70 - $title.Length)) -ForegroundColor DarkCyan
}

function Write-Pass([string]$msg) { Write-Host "  [PASS] $msg" -ForegroundColor DarkGreen }
function Write-Fail([string]$msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    $script:failures.Add($msg)
}

function Get-FileBytes([string]$path) { return [System.IO.File]::ReadAllBytes($path) }

function Test-HasBom([byte[]]$b) {
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Get-LoneLfCount([byte[]]$b) {
    $n = 0
    for ($i = 0; $i -lt $b.Length; $i++) {
        if ($b[$i] -eq 0x0A -and ($i -eq 0 -or $b[$i - 1] -ne 0x0D)) { $n++ }
    }
    return $n
}

function Get-CrCount([byte[]]$b) {
    $n = 0
    for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -eq 0x0D) { $n++ } }
    return $n
}

# ── 发现模组包 ──────────────────────────────────────────────────────────
Write-Section "发现模组包"
$modDirs = @(Get-ChildItem -LiteralPath $repoRoot -Directory |
    Where-Object { -not $_.Name.StartsWith(".") -and (Test-Path -LiteralPath (Join-Path $_.FullName "filelist.xml")) })

if ($modDirs.Count -eq 0) { throw "仓库根目录下没有找到任何含 filelist.xml 的模组包" }
$modDirs | ForEach-Object { Write-Host "  · $($_.Name)" }
Write-Pass "$($modDirs.Count) 个包：$(($modDirs | ForEach-Object { $_.Name }) -join ', ')"
Write-Host "  VERSION=$modVersion  GAMEVERSION=$gameVersion  TAG=$VersionTag"

# ── 门禁 1：XML 合法 + BOM + CRLF ───────────────────────────────────────
Write-Section "门禁 A：XML 合法 / BOM / CRLF"
$xmlTotal = 0; $xmlBad = 0
foreach ($mod in $modDirs) {
    foreach ($xml in Get-ChildItem -LiteralPath $mod.FullName -Filter *.xml -Recurse -File) {
        $xmlTotal++
        $rel = $xml.FullName.Substring($repoRoot.Length + 1)
        try { $null = [xml](Get-Content -LiteralPath $xml.FullName -Raw -Encoding UTF8) }
        catch { Write-Fail "$rel 无法解析：$($_.Exception.Message)"; $xmlBad++; continue }

        $b = Get-FileBytes $xml.FullName
        if (-not (Test-HasBom $b)) { Write-Fail "$rel 缺少 BOM（XML 需要 BOM）"; $xmlBad++; continue }
        $lone = Get-LoneLfCount $b
        if ($lone -gt 0) { Write-Fail "$rel 有 $lone 个裸 LF（XML 需要 CRLF）"; $xmlBad++; continue }
    }
}
if ($xmlBad -eq 0) { Write-Pass "$xmlTotal 个 XML：全部可解析，BOM 齐全，换行全为 CRLF" }

# ── 门禁 2：文本文件 BOM / 换行 ─────────────────────────────────────────
Write-Section "门禁 B：文本文件（无 BOM + LF）"
$textFiles = [System.Collections.Generic.List[string]]::new()
foreach ($mod in $modDirs) {
    foreach ($ext in @("*.cs", "*.lua")) {
        Get-ChildItem -LiteralPath $mod.FullName -Filter $ext -Recurse -File |
            ForEach-Object { $textFiles.Add($_.FullName) }
    }
}
foreach ($name in @("README.md", "README.en.md", "changes.md", "changes.en.md", "VERSION", "GAMEVERSION")) {
    $p = Join-Path $repoRoot $name
    if (Test-Path -LiteralPath $p) { $textFiles.Add($p) }
}
$textBad = 0
foreach ($p in $textFiles) {
    $rel = $p.Substring($repoRoot.Length + 1)
    $b = Get-FileBytes $p
    if (Test-HasBom $b) { Write-Fail "$rel 含 BOM（应为无 BOM）"; $textBad++; continue }
    $cr = Get-CrCount $b
    if ($cr -gt 0) { Write-Fail "$rel 含 $cr 个 CR（应为纯 LF）"; $textBad++; continue }
}
if ($textBad -eq 0) { Write-Pass "$($textFiles.Count) 个文本文件：无 BOM，换行全为 LF" }

# ── 门禁 2.5：PowerShell 脚本必须带 BOM ─────────────────────────────────
# Windows PowerShell 5.1 默认按 ANSI 读脚本，无 BOM 的 UTF-8 中文会被解成乱码并直接报语法错。
Write-Section "门禁 B2：PowerShell 脚本（需 BOM + LF）"
$psFiles = @()
foreach ($scanRoot in @((Join-Path $repoRoot "tools"), (Join-Path $repoRoot ".github"))) {
    if (Test-Path -LiteralPath $scanRoot) {
        $psFiles += @(Get-ChildItem -LiteralPath $scanRoot -Filter *.ps1 -Recurse -File)
    }
}
$psBad = 0
foreach ($p in $psFiles) {
    $rel = $p.FullName.Substring($repoRoot.Length + 1)
    $b = Get-FileBytes $p.FullName
    if (-not (Test-HasBom $b)) { Write-Fail "$rel 缺少 BOM（Windows PowerShell 5.1 会读错中文）"; $psBad++; continue }
    $lone = Get-LoneLfCount $b
    $cr = Get-CrCount $b
    if ($cr -gt 0 -and $lone -gt 0) { Write-Fail "$rel 混用 CRLF 与 LF"; $psBad++; continue }
}
if ($psBad -eq 0) { Write-Pass "$($psFiles.Count) 个 .ps1：BOM 齐全，换行一致" }

# ── 门禁 3：版本号一致性 ────────────────────────────────────────────────
Write-Section "门禁 C：版本号一致性"
$verBad = 0
foreach ($mod in $modDirs) {
    $filelist = Join-Path $mod.FullName "filelist.xml"
    [xml]$doc = Get-Content -LiteralPath $filelist -Raw -Encoding UTF8
    $root = $doc.DocumentElement
    $mv = $root.GetAttribute("modversion")
    $gv = $root.GetAttribute("gameversion")
    $name = $root.GetAttribute("name")

    if ($mv -ne $modVersion) { Write-Fail "$($mod.Name): modversion='$mv' 但 VERSION='$modVersion'"; $verBad++ }
    if ($gv -ne $gameVersion) { Write-Fail "$($mod.Name): gameversion='$gv' 但 GAMEVERSION='$gameVersion'"; $verBad++ }
    if ($verBad -eq 0) { Write-Host "  · $($mod.Name) → $name | modversion=$mv gameversion=$gv" }
}
if ($verBad -eq 0) { Write-Pass "所有 filelist 的 modversion / gameversion 与版本文件一致" }

# ── 门禁 4：包内清单可枚举 ──────────────────────────────────────────────
Write-Section "门禁 D：包内容"
$payloads = @{}
$payloadBad = 0
foreach ($mod in $modDirs) {
    $files = @(Get-ChildItem -LiteralPath $mod.FullName -Recurse -File)
    if ($files.Count -eq 0) { Write-Fail "$($mod.Name) 是空包"; $payloadBad++; continue }
    $payloads[$mod.Name] = $files
    $csCount = @($files | Where-Object { $_.Extension -eq ".cs" }).Count
    $luaCount = @($files | Where-Object { $_.Extension -eq ".lua" }).Count
    $xmlCount = @($files | Where-Object { $_.Extension -eq ".xml" }).Count
    Write-Host ("  · {0,-8} {1,3} 文件（{2} cs / {3} lua / {4} xml）" -f $mod.Name, $files.Count, $csCount, $luaCount, $xmlCount)
}
if ($payloadBad -eq 0) { Write-Pass "所有包非空且可枚举" }

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "门禁失败，$($failures.Count) 项未通过：" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  × $_" -ForegroundColor Red }
    throw "package-release.ps1 中止：请先修好上述问题"
}

# ── 打包 ────────────────────────────────────────────────────────────────
Write-Section "打包"

function New-PluginZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][array]$Entries,
        [Parameter(Mandatory = $true)][string]$RequiredPrefix
    )

    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

    $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($e in $Entries) {
                if (-not (Test-Path -LiteralPath $e.Source)) { throw "打包缺失源文件：'$($e.Source)'" }
                if ($e.EntryName.Contains('\')) { throw "ZIP 条目名禁止反斜杠：'$($e.EntryName)'" }
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $e.Source, $e.EntryName,
                    [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }

    $verify = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($verify.Entries.Count -ne $Entries.Count) {
            throw "ZIP 条目数不匹配（$ZipPath）：实际=$($verify.Entries.Count) 期望=$($Entries.Count)"
        }
        foreach ($entry in $verify.Entries) {
            if ($entry.FullName.Contains('\')) { throw "ZIP 含反斜杠条目：'$($entry.FullName)'" }
            if (-not $entry.FullName.StartsWith($RequiredPrefix, [System.StringComparison]::Ordinal)) {
                throw "ZIP 条目根路径异常：'$($entry.FullName)'（应以 $RequiredPrefix 开头）"
            }
            if ($entry.Length -le 0) { throw "ZIP 条目为空：'$($entry.FullName)'" }
        }
    } finally { $verify.Dispose() }
}

# 文档随包分发：放进每个模组目录内（与 BepInEx 生态的惯例一致）
$docPairs = @(
    @{ Source = (Join-Path $repoRoot "README.md"); Name = "README.md" },
    @{ Source = (Join-Path $repoRoot "changes.md"); Name = "changes.md" }
)

function Get-ModEntries([string]$modName) {
    $modPath = Join-Path $repoRoot $modName
    $list = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($f in Get-ChildItem -LiteralPath $modPath -Recurse -File) {
        $rel = $f.FullName.Substring($modPath.Length + 1).Replace('\', '/')
        $list.Add(@{ Source = $f.FullName; EntryName = "LocalMods/$modName/$rel" })
    }
    foreach ($d in $docPairs) {
        if (Test-Path -LiteralPath $d.Source) {
            $list.Add(@{ Source = $d.Source; EntryName = "LocalMods/$modName/$($d.Name)" })
        }
    }
    return $list
}

if (Test-Path -LiteralPath $OutputDir) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$modNames = @($modDirs | ForEach-Object { $_.Name })
$assets = [System.Collections.Generic.List[string]]::new()

# 单包 zip
foreach ($modName in $modNames) {
    $zipName = "$modName-$VersionTag.zip"
    New-PluginZipArchive -ZipPath (Join-Path $OutputDir $zipName) `
        -Entries (Get-ModEntries $modName) -RequiredPrefix "LocalMods/$modName/"
    $assets.Add($zipName)
}

# 合包 zip（两个包一起装的人用）
if ($modNames.Count -gt 1) {
    $bundle = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($modName in $modNames) { foreach ($e in Get-ModEntries $modName) { $bundle.Add($e) } }
    $bundleName = "XsCore-Barotrauma-$VersionTag.zip"
    New-PluginZipArchive -ZipPath (Join-Path $OutputDir $bundleName) `
        -Entries $bundle -RequiredPrefix "LocalMods/"
    $assets.Add($bundleName)
}

foreach ($name in $assets) {
    $p = Join-Path $OutputDir $name
    $size = [math]::Round((Get-Item -LiteralPath $p).Length / 1KB, 1)
    Write-Host ("  · {0,-40} {1,8} KB" -f $name, $size)
}

# ── 校验和 ──────────────────────────────────────────────────────────────
Write-Section "SHA256 校验和"
$hashLines = foreach ($name in $assets) {
    $p = Join-Path $OutputDir $name
    if (-not (Test-Path -LiteralPath $p) -or (Get-Item -LiteralPath $p).Length -le 0) {
        throw "产物缺失或为空：'$p'"
    }
    $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
    "$h  $name"
}
$sumsPath = Join-Path $OutputDir "SHA256SUMS.txt"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($sumsPath, (($hashLines -join "`n") + "`n"), $utf8NoBom)
$hashLines | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "完成：$($assets.Count + 1) 项发布资产 → $OutputDir" -ForegroundColor Green
Write-Host "版本 $modVersion ｜ 游戏 $gameVersion ｜ 标签 $VersionTag" -ForegroundColor Green
