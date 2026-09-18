<#
  Project checks for ai-pipeline (preset: none). Called by .ai/validate.ps1.
  Add this project's tests or build here. Arguments:
    -Root              repository root
    -ChangedFilesPath  file with lines '<status><TAB><path>' (files changed since the pipeline baseline)
    -Full              set when the pipeline runs with -FullValidation (slow checks go here)
  Output contract: print 'PASS  <what>', 'FAIL  <what>' or 'SKIP  <what>' lines; exit non-zero on failure.
  Keep output short (the auditor reads it) and make sure the checks write no files into the repository.
  This file belongs to the project: install.ps1 -Update never overwrites it.
  ASCII only (Windows PowerShell 5.1).
#>
param([Parameter(Mandatory = $true)][string]$Root, [string]$ChangedFilesPath, [switch]$Full)
$ErrorActionPreference = 'Continue'

# Example:
#   Push-Location -LiteralPath $Root
#   try { $out = & make test 2>&1; $code = $LASTEXITCODE } finally { Pop-Location }
#   @($out | ForEach-Object { "$_" }) | Select-Object -Last 40 | ForEach-Object { "    $_" }
#   if ($code -eq 0) { 'PASS  make test' } else { 'FAIL  make test'; exit 1 }

Write-Output 'SKIP  no project checks configured (.ai/checks.ps1)'
exit 0
