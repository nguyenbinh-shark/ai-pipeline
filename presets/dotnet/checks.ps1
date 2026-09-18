<#
  Project checks for ai-pipeline (preset: dotnet). Called by .ai/validate.ps1.
  Runs 'dotnet test' (which also builds) when a C#/project file changed, or with -Full.
  Output contract: lines 'PASS  ...' / 'FAIL  ...' / 'SKIP  ...'; non-zero exit on failure.
  This file belongs to the project: edit it freely (install.ps1 -Update never overwrites it).
  bin/ and obj/ must be in .gitignore, otherwise build output shows up as changes.
  ASCII only (Windows PowerShell 5.1).
#>
param([Parameter(Mandatory = $true)][string]$Root, [string]$ChangedFilesPath, [switch]$Full)
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding $false

$changed = @()
if ($ChangedFilesPath -and (Test-Path -LiteralPath $ChangedFilesPath)) {
    $changed = @([IO.File]::ReadAllLines($ChangedFilesPath, $utf8) | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split "`t")[-1] })
}
$relevant = @($changed | Where-Object { $_ -match '\.(cs|fs|vb|csproj|fsproj|vbproj|sln|props|targets)$' })
if (-not $Full -and $relevant.Count -eq 0) { Write-Output 'SKIP  dotnet test (no .NET file changed)'; exit 0 }

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { Write-Output 'SKIP  dotnet test (dotnet not found)'; exit 0 }
Push-Location -LiteralPath $Root
try { $out = & $dotnet.Source test --nologo -v q 2>&1; $code = $LASTEXITCODE } finally { Pop-Location }
@($out | ForEach-Object { "$_" }) | Select-Object -Last 40 | ForEach-Object { "    $_" }
if ($code -eq 0) { Write-Output 'PASS  dotnet test'; exit 0 }
Write-Output "FAIL  dotnet test (exit $code)"
exit 1
