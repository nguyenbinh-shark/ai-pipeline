<#
.SYNOPSIS
  Test suite for ai-pipeline. Builds a throw-away sample repository (path with spaces) in %TEMP%,
  installs the pipeline into it and checks install/update, every mock scenario, the protected-path
  and deletion checks, validation, model configuration, and optionally one real agent run.
.PARAMETER SkipCli
  Skip the tests that call agy/codex for their model catalogs (-CheckConfig). No tokens either way.
.PARAMETER Real
  Also run one real pipeline (agy + Codex) on a tiny task. Costs tokens (about 200k).
.PARAMETER Keep
  Keep the temporary repository even when every test passes.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
  ASCII only (Windows PowerShell 5.1).
#>
[CmdletBinding()]
param([switch]$SkipCli, [switch]$Real, [switch]$Keep)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Src = Split-Path -Parent $PSScriptRoot
$Ps = Join-Path $PSHOME 'powershell.exe'
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('ai-pipeline test ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Repo = Join-Path $Tmp 'sample project'
$script:Results = @()

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:Results += [pscustomobject]@{ Name = $Name; Ok = $Ok }
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $line = "$tag  $Name"
    if (-not $Ok -and $Detail) { $line += "  -- $Detail" }
    Write-Host $line
}
function WriteRepo([string]$Rel, [string]$Text) {
    $p = Join-Path $Repo $Rel
    $d = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($p, $Text, $Utf8)
}
function ReadRepo([string]$Rel) { return [IO.File]::ReadAllText((Join-Path $Repo $Rel), $Utf8) }
function G([string[]]$GitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & git -C $Repo -c user.name=ai-pipeline-test -c user.email=test@localhost -c core.autocrlf=false @GitArgs 2>&1 }
    finally { $ErrorActionPreference = $prev }
    return @($o | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
}
function Commit([string]$Msg) { [void](G @('add', '-A')); [void](G @('commit', '-q', '-m', $Msg)) }
function Run([string]$Script, [string[]]$ScriptArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $Ps -NoProfile -ExecutionPolicy Bypass -File $Script @ScriptArgs 2>&1; $c = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    return @{ Code = $c; Out = (@($o | ForEach-Object { "$_" }) -join "`n") }
}
function Pipe([string[]]$A) { return Run (Join-Path $Repo 'scripts\ai-pipeline.ps1') $A }
function Install([string[]]$A) { return Run (Join-Path $Src 'install.ps1') (@('-Target', $Repo) + $A) }
function LastRun { return (Get-ChildItem -LiteralPath (Join-Path $Repo '.ai\logs') -Directory | Sort-Object Name | Select-Object -Last 1).FullName }
function Clean { return (@(G @('status', '--porcelain', '--untracked-files=all')).Count -eq 0) }

Write-Host "test repo: $Repo"
New-Item -ItemType Directory -Force -Path $Repo | Out-Null
[void](G @('init', '-q'))
WriteRepo 'src/mathutil.py' "def clamp(x, lo, hi):`n    return max(lo, min(x, hi))`n`n`ndef safe_div(a, b, default=None):`n    if b == 0:`n        return default`n    return a / b`n"
WriteRepo 'tests/test_mathutil.py' ("import os`nimport sys`nimport unittest`n`nsys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src'))`n`nimport mathutil`n`n`n" +
    "class TestMathutil(unittest.TestCase):`n    def test_clamp(self):`n        self.assertEqual(mathutil.clamp(15, 0, 10), 10)`n`n    def test_safe_div(self):`n        self.assertIsNone(mathutil.safe_div(1, 0))`n`n`nif __name__ == '__main__':`n    unittest.main()`n")
WriteRepo 'mock-canary.txt' "canary`n"
WriteRepo '.gitignore' "__pycache__/`n"
Commit 'sample project'

# ------------------------------------------------------------------ install / update
$r = Install @('-SkipCheck')
Check 'install: fresh install exits 0' ($r.Code -eq 0) $r.Out
foreach ($f in 'scripts/ai-pipeline.ps1', '.ai/validate.ps1', '.ai/prompts/audit.md', '.ai/review.schema.json', '.ai/README.md',
    '.ai/checks.ps1', '.ai/plan.md', '.ai/protected-paths.txt', '.ai/context-ignore.txt', '.ai/pipeline-version.txt', 'AGENTS.md', 'GEMINI.md', 'CLAUDE.md') {
    Check "install: $f exists" (Test-Path -LiteralPath (Join-Path $Repo $f))
}
Check 'install: python preset auto-detected' ((ReadRepo '.ai/checks.ps1') -match 'preset: python')
Check 'install: blocks inserted' (((ReadRepo 'AGENTS.md') -match 'ai-pipeline:begin') -and ((ReadRepo 'CLAUDE.md') -match 'ai-pipeline:end'))

$r = Install @('-SkipCheck')
Check 'install: re-install without changes exits 0' ($r.Code -eq 0) $r.Out

WriteRepo 'CLAUDE.md' ("USER LINE KEEP`n`n" + (ReadRepo 'CLAUDE.md'))
WriteRepo '.ai/context-ignore.txt' ((ReadRepo '.ai/context-ignore.txt') + "project-only-entry/`n")
$fixOrig = ReadRepo '.ai/prompts/fix.md'
WriteRepo '.ai/prompts/fix.md' ($fixOrig + "local edit`n")
WriteRepo 'GEMINI.md' ((ReadRepo 'GEMINI.md') -replace 'Follow it; do not redesign it', 'LOCAL CHANGE')
$r = Install @('-SkipCheck')
Check 'install: modified core file -> refuses without -Update (exit 1)' ($r.Code -eq 1) $r.Out
Check 'install: refusal wrote nothing' ((ReadRepo '.ai/prompts/fix.md') -match 'local edit')
$r = Install @('-SkipCheck', '-Update')
Check 'install -Update: exits 0' ($r.Code -eq 0) $r.Out
Check 'install -Update: core file restored' ((ReadRepo '.ai/prompts/fix.md') -eq $fixOrig)
Check 'install -Update: block restored' (-not ((ReadRepo 'GEMINI.md') -match 'LOCAL CHANGE'))
Check 'install -Update: text outside block kept' ((ReadRepo 'CLAUDE.md') -match 'USER LINE KEEP')
Check 'install -Update: project file kept' ((ReadRepo '.ai/context-ignore.txt') -match 'project-only-entry')

WriteRepo '.ai/protected-paths.txt' ((ReadRepo '.ai/protected-paths.txt') + "mock-canary.txt`n")
Commit 'install ai-pipeline'

# ------------------------------------------------------------------ setup refusals
$r = Pipe @('-Mock', 'pass')
Check 'pipeline: template plan -> exit 2' ($r.Code -eq 2) $r.Out
WriteRepo '.ai/plan.md' "# Plan`n`n## Task`nTest plan for the ai-pipeline test suite.`n"
Commit 'plan'
WriteRepo 'scratch.txt' 'uncommitted'
$r = Pipe @('-Mock', 'pass')
Check 'pipeline: dirty tree without -AllowDirty -> exit 2' ($r.Code -eq 2) $r.Out
[IO.File]::Delete((Join-Path $Repo 'scratch.txt'))

# ------------------------------------------------------------------ mock scenarios
$expect = [ordered]@{ 'pass' = 0; 'fail-then-pass' = 0; 'always-fail' = 1; 'bad-json' = 3; 'escalate-lead' = 4; 'repeat-finding' = 4; 'escalate-implementer' = 0 }
foreach ($m in $expect.Keys) {
    $r = Pipe @('-Mock', $m)
    Check "mock ${m}: exit $($expect[$m])" ($r.Code -eq $expect[$m]) ("exit $($r.Code)`n" + $r.Out)
    $run = LastRun
    $sum = if (Test-Path -LiteralPath "$run\summary.md") { [IO.File]::ReadAllText("$run\summary.md", $Utf8) } else { '' }
    Check "mock ${m}: summary has AI Usage" ($sum -match '## AI Usage' -and $sum -match 'Total agent calls')
    if ($m -eq 'always-fail') { Check 'mock always-fail: 3 rounds' (Test-Path -LiteralPath "$run\round-3") }
    if ($m -eq 'repeat-finding') { Check 'mock repeat-finding: stops after round 2' ((Test-Path -LiteralPath "$run\round-2") -and -not (Test-Path -LiteralPath "$run\round-3")) }
    if ($m -like 'escalate-lead' -or $m -eq 'repeat-finding') { Check "mock ${m}: escalation.md written" (Test-Path -LiteralPath "$run\escalation.md") }
    if ($m -eq 'escalate-implementer') { Check 'mock escalate-implementer: round 2 used escalation model' ($sum -match '\| agy \| 2 \| gemini-3\.1-pro') }
    if ($m -eq 'fail-then-pass') { Check 'mock fail-then-pass: round 2 has targeted re-review inputs' ((Test-Path -LiteralPath "$run\round-2\previous-review.json") -and (Test-Path -LiteralPath "$run\round-2\diff-round.patch")) }
}
Check 'mock runs left the working tree clean' (Clean)

$r = Pipe @('-Mock', 'canary-edit')
$rv = ReadRepo '.ai/review.json'
Check 'canary-edit: protected path detected' ($rv -match 'Protected path changed: mock-canary.txt') $r.Out
Check 'canary-edit: persisting finding -> exit 4' ($r.Code -eq 4) $r.Out
WriteRepo 'mock-canary.txt' "canary`n"
$r = Pipe @('-Mock', 'canary-delete')
$rv = ReadRepo '.ai/review.json'
Check 'canary-delete: deletion detected' ($rv -match 'File deleted: mock-canary.txt') $r.Out
Check 'canary-delete: exit 4' ($r.Code -eq 4) $r.Out
WriteRepo 'mock-canary.txt' "canary`n"
Check 'canary tests restored the tree' (Clean)

# ------------------------------------------------------------------ validation
$val = Join-Path $Repo '.ai\validate.ps1'
$list = Join-Path $Tmp 'changed.txt'
[IO.File]::WriteAllText($list, "M`tsrc/mathutil.py`n", $Utf8)
$r = Run $val @('-Root', $Repo, '-ChangedFilesPath', $list)
Check 'validate: good change -> PASS and project tests ran' ($r.Code -eq 0 -and $r.Out -match 'VALIDATION_STATUS=PASS' -and $r.Out -match 'PASS  (unittest|pytest)') $r.Out
WriteRepo 'src/broken.py' "def broken(:`n"
[IO.File]::WriteAllText($list, "A`tsrc/broken.py`n", $Utf8)
$r = Run $val @('-Root', $Repo, '-ChangedFilesPath', $list)
Check 'validate: syntax error -> FAIL exit 1' ($r.Code -eq 1 -and $r.Out -match 'FAIL  src/broken.py python syntax') $r.Out
[IO.File]::Delete((Join-Path $Repo 'src\broken.py'))
WriteRepo 'tests/test_fail.py' "import unittest`n`n`nclass T(unittest.TestCase):`n    def test_x(self):`n        self.assertEqual(1, 2)`n"
[IO.File]::WriteAllText($list, "A`ttests/test_fail.py`n", $Utf8)
$r = Run $val @('-Root', $Repo, '-ChangedFilesPath', $list)
Check 'validate: failing test -> FAIL exit 1' ($r.Code -eq 1 -and $r.Out -match 'FAIL  (unittest|pytest)') $r.Out
[IO.File]::Delete((Join-Path $Repo 'tests\test_fail.py'))
Check 'validation left the working tree clean' (Clean) ((G @('status', '--porcelain', '--untracked-files=all')) -join ', ')

# ------------------------------------------------------------------ model configuration (calls agy/codex catalogs, no tokens)
if (-not $SkipCli) {
    $r = Pipe @('-CheckConfig')
    Check 'config: defaults validate (CONFIG_STATUS=OK)' ($r.Code -eq 0 -and $r.Out -match 'CONFIG_STATUS=OK') $r.Out
    $env:AI_AGY_EFFORT = 'high'; $env:AI_CODEX_EFFORT = 'high'
    $r = Pipe @('-CheckConfig')
    Check 'config: env override is applied' ($r.Code -eq 0 -and $r.Out -match 'env AI_AGY_EFFORT' -and $r.Out -match 'reasoning effort=high') $r.Out
    [Environment]::SetEnvironmentVariable('AI_AGY_EFFORT', $null); [Environment]::SetEnvironmentVariable('AI_CODEX_EFFORT', $null)
    $env:AI_AGY_MODEL = 'no-such-model'
    $r = Pipe @('-CheckConfig')
    Check 'config: invalid agy model -> exit 2, no fallback' ($r.Code -eq 2 -and $r.Out -match "not in 'agy models'") $r.Out
    [Environment]::SetEnvironmentVariable('AI_AGY_MODEL', $null)
    $env:AI_CODEX_EFFORT = 'bogus'
    $r = Pipe @('-CheckConfig')
    Check 'config: invalid codex effort -> exit 2' ($r.Code -eq 2 -and $r.Out -match 'not supported by') $r.Out
    [Environment]::SetEnvironmentVariable('AI_CODEX_EFFORT', $null)
    $r = Pipe @('-CheckConfig', '-CodexModel', 'no-such-codex')
    Check 'config: invalid codex model (parameter) -> exit 2' ($r.Code -eq 2 -and $r.Out -match "not in 'codex debug models'") $r.Out
}

# ------------------------------------------------------------------ real run (tokens)
if ($Real) {
    WriteRepo '.ai/plan.md' @"
# Plan

## Task
Add a ``lerp`` helper to the sample module and a unittest for it (ai-pipeline smoke test).

## Context found in the repository
- ``src/mathutil.py`` has ``clamp`` and ``safe_div``; 4-space indent, no docstrings.
- ``tests/test_mathutil.py`` is a unittest module importing ``mathutil`` through ``sys.path``.

## Implementation steps
1. ``src/mathutil.py`` - add ``lerp(a, b, t)`` returning ``a + (b - a) * t``; raise ``ValueError`` if ``t`` is outside [0, 1].
2. ``tests/test_mathutil.py`` - add ``test_lerp``: t = 0, 0.5, 1, and ``ValueError`` for -0.1 and 1.1.

## Out of scope
- Do not change ``clamp``, ``safe_div``, their tests, or ``mock-canary.txt``.

## Acceptance criteria
- [ ] ``lerp(0, 10, 0.5) == 5``; endpoints exact; out-of-range t raises ``ValueError``.
- [ ] Existing tests unchanged and passing.

## Validation
- ``.ai/checks.ps1`` runs the unit tests.
"@
    Commit 'smoke plan'
    Write-Host 'real run: agy + Codex (a few minutes)...'
    $r = Pipe @()
    $run = LastRun
    Check 'real: pipeline exit 0 (PASS)' ($r.Code -eq 0) $r.Out
    $meta = [IO.File]::ReadAllText("$run\run.json", $Utf8) | ConvertFrom-Json
    $agyU = @($meta.usage | Where-Object { $_.agent -eq 'agy' })[0]
    $cdxU = @($meta.usage | Where-Object { $_.agent -eq 'codex' })[0]
    Check 'real: agy token usage captured' ($null -ne $agyU.input -and $null -ne $agyU.total)
    Check 'real: codex token usage captured' ($null -ne $cdxU.input -and $null -ne $cdxU.output)
    Check 'real: agy resolved model matches request' ($agyU.cli_resolved_model -ne 'unavailable' -and $agyU.cli_resolved_model -ne 'mock')
    $leak = @(Get-ChildItem -LiteralPath $run -Recurse -File | Select-String -Pattern 'sk-[A-Za-z0-9_\-]{16,}|AIza[0-9A-Za-z_\-]{30,}|ya29\.[0-9A-Za-z_\-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}').Count
    Check 'real: no secret patterns in logs' ($leak -eq 0)
    $s = [IO.File]::ReadAllText("$run\summary.md", $Utf8)
    Write-Host ($s.Substring($s.IndexOf('## AI Usage')))
}

# ------------------------------------------------------------------ report
$failed = @($script:Results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("{0} checks, {1} failed" -f $script:Results.Count, $failed.Count)
if ($failed.Count -eq 0 -and -not $Keep) { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
else { Write-Host "test repo kept: $Repo" }
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
