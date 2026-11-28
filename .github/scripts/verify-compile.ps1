[CmdletBinding()]
param(
    # 游戏根目录，例如 E:\SteamLibrary\steamapps\common\Barotrauma
    [Parameter(Mandatory = $false)]
    [string]$GameDir = "",

    # 要检查的模组包名，逗号或空格分隔；all = 所有含 CSharp\*.cs 的包
    [Parameter(Mandatory = $false)]
    [string]$Mods = "all",

    # 找不到游戏时只打警告并成功退出（CI 用）
    [Parameter(Mandatory = $false)]
    [switch]$AllowSkip
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step([string]$m) { Write-Host ">>> $m" -ForegroundColor Cyan }

# ── 1. 定位游戏目录 ────────────────────────────────────────────────────
function Resolve-GameDir {
    param([string]$Explicit)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Explicit) { $candidates.Add($Explicit) }
    if ($env:BAROTRAUMA_DIR) { $candidates.Add($env:BAROTRAUMA_DIR) }

    # 从 Steam 的 libraryfolders.vdf 里找出所有库，再拼常见路径
    $steamRoots = @(
        "$env:ProgramFiles(x86)\Steam",
        "$env:ProgramFiles\Steam",
        "E:\SteamLibrary",
        "D:\SteamLibrary"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($root in $steamRoots) {
        $candidates.Add((Join-Path $root "steamapps\common\Barotrauma"))
        $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            $txt = Get-Content -LiteralPath $vdf -Raw
            foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                $candidates.Add((Join-Path $lib "steamapps\common\Barotrauma"))
            }
        }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c "Barotrauma.dll"))) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

Write-Step "定位游戏目录"
$dir = Resolve-GameDir -Explicit $GameDir
if (-not $dir) {
    $msg = "未找到 Barotrauma 安装目录。请用 -GameDir 指定，或设置环境变量 BAROTRAUMA_DIR。"
    if ($AllowSkip) { Write-Host "  [跳过] $msg" -ForegroundColor Yellow; exit 0 }
    throw $msg
}
Write-Host "  $dir" -ForegroundColor DarkGray

# ── 2. 收集引用程序集 ──────────────────────────────────────────────────
Write-Step "收集引用程序集"
$refPatterns = @(
    "Barotrauma.dll",
    "BarotraumaCore.dll",
    # DedicatedServer.dll 与 Barotrauma.dll 有同名类型（Character/Item/Submarine），
    # 一起引用会触发 CS0433 二义性，模组代码也用不到它，故不引用。
    "0Harmony.dll",
    "XNATypes.dll",
    "MonoGame.Framework*.dll",
    "LuaCs.Temp\Client\LuaCsForBarotraumaPluginClient.dll",
    "LuaCs.Temp\Client\MoonSharp.Interpreter.dll"
)
$refs = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($pat in $refPatterns) {
    Get-ChildItem -Path (Join-Path $dir $pat) -File -ErrorAction SilentlyContinue |
        ForEach-Object { $refs.Add($_) }
}

if (-not ($refs | Where-Object { $_.Name -eq "Barotrauma.dll" })) { throw "缺少 Barotrauma.dll" }
if (-not ($refs | Where-Object { $_.Name -like "LuaCsForBarotraumaPluginClient.dll" })) {
    $msg = "缺少 LuaCs 客户端程序集（LuaCs.Temp\Client）。先启动一次游戏让 LuaCs 展开运行时，再跑本脚本。"
    if ($AllowSkip) { Write-Host "  [跳过] $msg" -ForegroundColor Yellow; exit 0 }
    throw $msg
}
$refs | ForEach-Object { Write-Host ("  · {0,-46} {1,7} KB" -f $_.Name, [math]::Round($_.Length / 1KB, 1)) }

# ── 3. 选定要检查的模组 ────────────────────────────────────────────────
Write-Step "选定模组包"
$allMods = @(Get-ChildItem -LiteralPath $repoRoot -Directory |
    Where-Object { -not $_.Name.StartsWith(".") -and (Test-Path -LiteralPath (Join-Path $_.FullName "filelist.xml")) -and
                   (Test-Path -LiteralPath (Join-Path $_.FullName "CSharp")) })

if ($allMods.Count -eq 0) { Write-Host "  [跳过] 仓库里没有含 CSharp 目录的模组包" -ForegroundColor Yellow; exit 0 }

$selected = $allMods
if ($Mods -and $Mods -ne "all") {
    $wanted = $Mods -split '[,;\s]+' | Where-Object { $_ }
    $selected = @($allMods | Where-Object { $wanted -contains $_.Name })
    if ($selected.Count -eq 0) { throw "没有匹配的模组包：$Mods（可选：$(($allMods | ForEach-Object { $_.Name }) -join ', ')）" }
}
$selected | ForEach-Object { Write-Host "  · $($_.Name)" }

$csFiles = @($selected | ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName "CSharp") -Filter *.cs -Recurse -File })
if ($csFiles.Count -eq 0) { Write-Host "  [跳过] 选中的包没有 .cs" -ForegroundColor Yellow; exit 0 }
Write-Host ("  {0} 个 .cs" -f $csFiles.Count) -ForegroundColor DarkGray

# ── 4. 生成临时工程 ────────────────────────────────────────────────────
$work = Join-Path ([System.IO.Path]::GetTempPath()) "xscore-compile-check"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

$compileItems = ($csFiles | ForEach-Object { "    <Compile Include=`"$($_.FullName)`" />" }) -join "`n"
$refItems = ($refs | ForEach-Object {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        "    <Reference Include=`"$name`"><HintPath>$($_.FullName)</HintPath><Private>false</Private></Reference>"
    }) -join "`n"

# LuaCs 编译模组代码时会注入一批隐式 using，这里照抄，否则 IAssemblyPlugin 之类的短名找不到
$csproj = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <AssemblyName>XsCompileCheck</AssemblyName>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>
    <Nullable>disable</Nullable>
    <LangVersion>latest</LangVersion>
    <NoWarn>`$(NoWarn);MSB3277;CS0168;CS0219;CS8509</NoWarn>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
  </PropertyGroup>
  <ItemGroup>
$compileItems
  </ItemGroup>
  <ItemGroup>
    <Using Include="Barotrauma" />
    <Using Include="Barotrauma.LuaCs" />
    <Using Include="HarmonyLib" />
    <Using Include="Microsoft.Xna.Framework" />
  </ItemGroup>
  <ItemGroup>
$refItems
  </ItemGroup>
</Project>
"@
$csprojPath = Join-Path $work "XsCompileCheck.csproj"
[System.IO.File]::WriteAllText($csprojPath, $csproj, [System.Text.UTF8Encoding]::new($false))

# ── 5. 编译 ────────────────────────────────────────────────────────────
Write-Step "编译校验"
Push-Location $work
try { $raw = & dotnet build -c Release --nologo -v q 2>&1 | Out-String } finally { Pop-Location }

$lines = $raw -split "`r?`n"
$errors = @($lines | Where-Object { $_ -match ':\s*error\s+[A-Z]+\d+' })
$warns = @($lines | Where-Object { $_ -match ':\s*warning\s+[A-Z]+\d+' -and $_ -notmatch 'MSB3277' })
$succeeded = $raw -match '已成功生成|Build succeeded'

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "编译失败，$($errors.Count) 个错误：" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    if ($warns.Count -gt 0) {
        Write-Host ""
        Write-Host "相关警告：" -ForegroundColor Yellow
        $warns | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }
    exit 1
}

if (-not $succeeded) {
    Write-Host "编译状态未知，原始输出：" -ForegroundColor Yellow
    Write-Host $raw
    exit 1
}

Write-Host "  编译通过：0 错误" -ForegroundColor DarkGreen
if ($warns.Count -gt 0) {
    Write-Host "  $($warns.Count) 条警告：" -ForegroundColor Yellow
    $warns | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
} else {
    Write-Host "  0 警告" -ForegroundColor DarkGreen
}
Write-Host ""
Write-Host "对照程序集版本：$((Get-Item -LiteralPath (Join-Path $dir 'Barotrauma.dll')).VersionInfo.FileVersion)" -ForegroundColor DarkGray
exit 0
