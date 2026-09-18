<#
  Project checks for ai-pipeline (preset: python). Called by .ai/validate.ps1.
  Runs the test suite when a .py file changed (or with -Full): pytest if installed, else unittest.
  Output contract: lines 'PASS  ...' / 'FAIL  ...' / 'SKIP  ...'; non-zero exit on failure.
  This file belongs to the project: edit it freely (install.ps1 -Update never overwrites it).
  ASCII only (Windows PowerShell 5.1).
#>
param([Parameter(Mandatory = $true)][string]$Root, [string]$ChangedFilesPath, [switch]$Full)
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding $false

$changed = @()
if ($ChangedFilesPath -and (Test-Path -LiteralPath $ChangedFilesPath)) {
    $changed = @([IO.File]::ReadAllLines($ChangedFilesPath, $utf8) | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split "`t")[-1] })
}
$relevant = @($changed | Where-Object { $_ -match '\.py$|(^|/)(pyproject\.toml|setup\.cfg|pytest\.ini|tox\.ini|requirements[^/]*\.txt)$' })
if (-not $Full -and $relevant.Count -eq 0) { Write-Output 'SKIP  tests (no Python file changed)'; exit 0 }

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { Write-Output 'SKIP  tests (python not found)'; exit 0 }

Push-Location -LiteralPath $Root
try {
    # -B and no cacheprovider: tests must not leave files that look like agent changes
    & $python.Source -c 'import pytest' 2>$null
    if ($LASTEXITCODE -eq 0) {
        $name = 'pytest'
        $out = & $python.Source -B -m pytest -q -p no:cacheprovider 2>&1
    } else {
        $name = 'unittest'
        $start = if (Test-Path -LiteralPath (Join-Path $Root 'tests')) { 'tests' } else { '.' }
        $out = & $python.Source -B -m unittest discover -s $start 2>&1
    }
    $code = $LASTEXITCODE
} finally { Pop-Location }

# keep the log compact: the tail is where test runners print the summary and failures
$lines = @($out | ForEach-Object { "$_" })
$lines | Select-Object -Last 40 | ForEach-Object { "    $_" }
if ($code -eq 5 -and $name -eq 'pytest') { Write-Output 'SKIP  pytest collected no tests'; exit 0 }
if ($code -eq 0) { Write-Output "PASS  $name"; exit 0 }
Write-Output "FAIL  $name (exit $code)"
exit 1
