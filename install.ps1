<#
.SYNOPSIS
  Installs (or updates) the ai-pipeline into a git repository.
.DESCRIPTION
  Core files (template/core) are copied into the target. They belong to ai-pipeline: a fresh install
  refuses to overwrite a core file whose content differs; -Update replaces them.
  Project files are created only when missing and are never overwritten:
    .ai/plan.md, .ai/protected-paths.txt, .ai/context-ignore.txt, .ai/checks.ps1 (from a preset), AGENTS.md
  Marked blocks (<!-- ai-pipeline:begin --> ... <!-- ai-pipeline:end -->) are inserted into or
  replaced in AGENTS.md, GEMINI.md and CLAUDE.md; the rest of those files is left untouched.
  Nothing is committed. All conflicts are checked before anything is written.
  Exit codes: 0 ok, 1 conflict (use -Update), 2 usage error, 3 -CheckConfig failed after install.
  ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -Target "D:\work\my project"
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -Target "D:\work\my project" -Update
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [switch]$Update,
    [ValidateSet('auto', 'python', 'node', 'dotnet', 'none')][string]$Preset = 'auto',
    [switch]$InitGit,
    [switch]$SkipCheck,
    [switch]$DryRun
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Src = $PSScriptRoot
$Begin = '<!-- ai-pipeline:begin -->'
$End = '<!-- ai-pipeline:end -->'

function Read-Utf8([string]$Path) { return [IO.File]::ReadAllText($Path, $Utf8) }
function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}
function Invoke-GitQuiet([string[]]$GitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & git @GitArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return @{ Code = $code; Out = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) }
}

# ------------------------------------------------------------------ target
if (-not (Test-Path -LiteralPath $Target -PathType Container)) { Write-Host "Target folder not found: $Target"; exit 2 }
$Target = (Resolve-Path -LiteralPath $Target).ProviderPath.TrimEnd('\')
$g = Invoke-GitQuiet @('-C', $Target, 'rev-parse', '--show-toplevel')
if ($g.Code -ne 0) {
    if (-not $InitGit) { Write-Host "Not a git repository: $Target  (run 'git init' there, or re-run with -InitGit)"; exit 2 }
    if (-not $DryRun) { [void](Invoke-GitQuiet @('init', '-q', $Target)) }
    Write-Host "git init: $Target"
    $Root = $Target
} else {
    $Root = (Resolve-Path -LiteralPath $g.Out[0]).ProviderPath.TrimEnd('\')
    if ($Root -ne $Target) { Write-Host "Target is inside a repository; installing at its root: $Root" }
}

if ($Preset -eq 'auto') {
    $Preset = 'none'
    $near = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.venv|venv|bin|obj)\\' } | ForEach-Object { $_.Name })
    if (Test-Path -LiteralPath (Join-Path $Root 'package.json')) { $Preset = 'node' }
    elseif ($near | Where-Object { $_ -match '\.(sln|csproj|fsproj)$' }) { $Preset = 'dotnet' }
    elseif ($near | Where-Object { $_ -match '^(pyproject\.toml|setup\.py|setup\.cfg|requirements.*\.txt)$|\.py$' }) { $Preset = 'python' }
    Write-Host "preset (auto-detected): $Preset"
}

# ------------------------------------------------------------------ plan all actions first
$actions = New-Object System.Collections.ArrayList   # @{ Path; Text; Kind }
$conflicts = @()

$coreDir = Join-Path $Src 'template\core'
foreach ($f in Get-ChildItem -LiteralPath $coreDir -File -Recurse -Force) {
    $rel = $f.FullName.Substring($coreDir.Length).TrimStart('\')
    $dest = Join-Path $Root $rel
    $text = Read-Utf8 $f.FullName
    if (-not (Test-Path -LiteralPath $dest)) { [void]$actions.Add(@{ Path = $dest; Text = $text; Kind = 'create' }) }
    elseif ((Read-Utf8 $dest) -ne $text) {
        if ($Update) { [void]$actions.Add(@{ Path = $dest; Text = $text; Kind = 'update' }) } else { $conflicts += $rel }
    }
}

$projDir = Join-Path $Src 'template\project'
foreach ($f in Get-ChildItem -LiteralPath $projDir -File -Recurse -Force) {
    $rel = $f.FullName.Substring($projDir.Length).TrimStart('\')
    $dest = Join-Path $Root $rel
    if ($rel -eq 'AGENTS.md') { continue }   # handled with its block below
    if (-not (Test-Path -LiteralPath $dest)) { [void]$actions.Add(@{ Path = $dest; Text = (Read-Utf8 $f.FullName); Kind = 'create (project file)' }) }
}
$checks = Join-Path $Root '.ai\checks.ps1'
if (-not (Test-Path -LiteralPath $checks)) {
    [void]$actions.Add(@{ Path = $checks; Text = (Read-Utf8 (Join-Path $Src "presets\$Preset\checks.ps1")); Kind = "create (project file, preset $Preset)" })
}

$blockFiles = [ordered]@{
    'AGENTS.md' = (Read-Utf8 (Join-Path $projDir 'AGENTS.md')).TrimEnd() + "`n"
    'GEMINI.md' = "# GEMINI.md`n"
    'CLAUDE.md' = "# CLAUDE.md`n"
}
foreach ($name in $blockFiles.Keys) {
    $blockName = $name -replace '\.md$', '.block.md'
    $block = $Begin + "`n" + (Read-Utf8 (Join-Path $Src "template\blocks\$blockName")).TrimEnd() + "`n" + $End
    $dest = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $dest)) {
        [void]$actions.Add(@{ Path = $dest; Text = ($blockFiles[$name] + "`n" + $block + "`n"); Kind = 'create' })
        continue
    }
    $cur = Read-Utf8 $dest
    $i = $cur.IndexOf($Begin); $j = $cur.IndexOf($End)
    if ($i -ge 0 -and $j -gt $i) {
        $new = $cur.Substring(0, $i) + $block + $cur.Substring($j + $End.Length)
        if ($new -ne $cur) {
            if ($Update) { [void]$actions.Add(@{ Path = $dest; Text = $new; Kind = 'update block' }) } else { $conflicts += "$name (pipeline block)" }
        }
    } else {
        [void]$actions.Add(@{ Path = $dest; Text = ($cur.TrimEnd() + "`n`n" + $block + "`n"); Kind = 'append block' })
    }
}

$ver = [regex]::Match((Read-Utf8 (Join-Path $coreDir 'scripts\ai-pipeline.ps1')), "PipelineVersion = '([^']+)'").Groups[1].Value
$verText = "ai-pipeline $ver`ninstalled: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`nsource: $Src`n"
$verPath = Join-Path $Root '.ai\pipeline-version.txt'
if (-not (Test-Path -LiteralPath $verPath) -or -not (Read-Utf8 $verPath).StartsWith("ai-pipeline $ver`n")) {
    [void]$actions.Add(@{ Path = $verPath; Text = $verText; Kind = 'write' })
}

if ($conflicts.Count -gt 0) {
    Write-Host 'These pipeline files already exist with different content:'
    $conflicts | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Nothing was written. Re-run with -Update to replace them (project files are never overwritten).'
    exit 1
}

# ------------------------------------------------------------------ apply
foreach ($a in $actions) {
    $rel = $a.Path.Substring($Root.Length).TrimStart('\')
    Write-Host ('{0,-40} {1}' -f $a.Kind, $rel)
    if (-not $DryRun) { Write-Utf8 $a.Path $a.Text }
}
if ($DryRun) { Write-Host 'Dry run: nothing written.'; exit 0 }
Write-Host "Installed ai-pipeline $ver into $Root (nothing committed)."

if (-not $SkipCheck) {
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\ai-pipeline.ps1') -RepoRoot $Root -CheckConfig
    if ($LASTEXITCODE -ne 0) { Write-Host 'Installed, but -CheckConfig failed (see above).'; exit 3 }
}
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Fill in AGENTS.md (TODO lines) if it was just created.'
Write-Host '  2. Review .ai/protected-paths.txt, .ai/context-ignore.txt and .ai/checks.ps1 for this project.'
Write-Host '  3. Ask Claude: "dung pipeline: <task>"  (guide: .ai/README.md)'
exit 0
