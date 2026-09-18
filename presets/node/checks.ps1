<#
  Project checks for ai-pipeline (preset: node). Called by .ai/validate.ps1.
  Runs 'npm test' when a JS/TS/package file changed (or with -Full), if package.json defines a test script.
  Output contract: lines 'PASS  ...' / 'FAIL  ...' / 'SKIP  ...'; non-zero exit on failure.
  This file belongs to the project: edit it freely (install.ps1 -Update never overwrites it).
  Make sure your test runner writes no files into the repository (coverage, snapshots), or add them
  to .gitignore, otherwise they show up as changes in the next round.
  ASCII only (Windows PowerShell 5.1).
#>
param([Parameter(Mandatory = $true)][string]$Root, [string]$ChangedFilesPath, [switch]$Full)
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding $false

$changed = @()
if ($ChangedFilesPath -and (Test-Path -LiteralPath $ChangedFilesPath)) {
    $changed = @([IO.File]::ReadAllLines($ChangedFilesPath, $utf8) | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split "`t")[-1] })
}
$relevant = @($changed | Where-Object { $_ -match '\.(js|jsx|mjs|cjs|ts|tsx|vue|svelte)$|(^|/)(package\.json|tsconfig[^/]*\.json)$' })
if (-not $Full -and $relevant.Count -eq 0) { Write-Output 'SKIP  npm test (no JS/TS file changed)'; exit 0 }

$pkg = Join-Path $Root 'package.json'
if (-not (Test-Path -LiteralPath $pkg)) { Write-Output 'SKIP  npm test (no package.json)'; exit 0 }
$scripts = ([IO.File]::ReadAllText($pkg, $utf8) | ConvertFrom-Json).PSObject.Properties['scripts']
if (-not $scripts -or -not $scripts.Value.PSObject.Properties['test']) { Write-Output 'SKIP  npm test (no "test" script in package.json)'; exit 0 }
$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npm) { Write-Output 'SKIP  npm test (npm not found)'; exit 0 }

Push-Location -LiteralPath $Root
try { $env:CI = 'true'; $out = & $npm.Source test --silent 2>&1; $code = $LASTEXITCODE } finally { Pop-Location }
@($out | ForEach-Object { "$_" }) | Select-Object -Last 40 | ForEach-Object { "    $_" }
if ($code -eq 0) { Write-Output 'PASS  npm test'; exit 0 }
Write-Output "FAIL  npm test (exit $code)"
exit 1
