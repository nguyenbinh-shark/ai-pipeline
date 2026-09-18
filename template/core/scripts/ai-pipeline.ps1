<#
.SYNOPSIS
  Multi-agent pipeline: agy/Gemini implements -> validation -> Codex audits -> fix loop.

.DESCRIPTION
  Claude (lead) writes .ai/plan.md and then runs this script. Per round:
    1. agy (Antigravity CLI, Gemini model) edits files: round 1 follows .ai/prompts/implement.md,
       later rounds follow .ai/prompts/fix.md using .ai/review.json.
    2. The script snapshots the working tree (temporary git index, the real index is not touched),
       diffs it against the baseline taken before round 1, checks protected paths and deletions,
       and runs .ai/validate.ps1.
    3. Codex audits in a read-only sandbox and returns JSON that follows .ai/review.schema.json.
    4. Pipeline findings are merged in and the result is written to .ai/review.json.
  Stops on PASS (no critical/major finding) or after -MaxRounds audits.
  Round 2+ is a targeted re-review: Codex gets the previous review and the fix-round patch.

  Escalation (see Get-Escalation):
    - Codex recommends escalate_implementer -> later rounds use the AGY escalation model.
    - A blocking finding in category architecture/concurrency/data-corruption/ambiguous-requirement,
      a critical security finding, Codex recommending escalate_lead, or the same blocking finding in
      two consecutive rounds -> stop, exit 4: the lead (Claude) must re-plan.

  Models are always passed explicitly and validated before any agent runs (no silent fallback):
    agy model  = catalog id from 'agy models' ('<model>-<effort>' when effort is set)
    codex      = slug + reasoning effort from 'codex debug models'
  Precedence: parameter > environment variable > defaults in $DefaultConfig below.
    AI_AGY_MODEL, AI_AGY_EFFORT, AI_AGY_ESCALATION_MODEL, AI_AGY_ESCALATION_EFFORT,
    AI_CODEX_MODEL, AI_CODEX_EFFORT   (effort 'none' = no effort suffix, for agy models without one)
  -CheckConfig prints the resolved configuration, validates it and exits (no agent is run).

  The script never commits, pushes, resets, cleans, checks out or stashes. The only thing it writes
  into .git is loose objects for the snapshot trees (harmless; git gc removes them).
  agy runs without shell permission (headless mode auto-denies it), so it cannot run git either.

  Exit codes: 0 PASS, 1 still FAIL after MaxRounds, 2 setup/usage/config error, 3 agent or tool error,
  4 escalated to the lead (re-plan needed; see escalation.md in the run folder).
  ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

.PARAMETER Mock
  Test the loop without calling any agent: pass | fail-then-pass | always-fail | bad-json |
  escalate-lead | repeat-finding | escalate-implementer | canary-edit | canary-delete.
  Models are resolved but not validated. canary-* append to / delete mock-canary.txt (only that file,
  only if it exists) to test the protected-path and deletion checks.

  Project settings (never overwritten by install.ps1 -Update):
    .ai/protected-paths.txt  extra protected patterns (the pipeline's own files are always protected)
    .ai/context-ignore.txt   paths agents must not read unless the plan points there
    .ai/checks.ps1           project checks called by .ai/validate.ps1 (tests, build)

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ai-pipeline.ps1 -AllowDirty
.EXAMPLE
  $env:AI_AGY_EFFORT = 'high'; $env:AI_CODEX_EFFORT = 'high'; .\scripts\ai-pipeline.ps1 -AllowDirty
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [ValidateRange(1, 10)][int]$MaxRounds = 3,
    [string]$AgyModel = '',
    [string]$AgyEffort = '',
    [string]$CodexModel = '',
    [string]$CodexEffort = '',
    [ValidateRange(1, 240)][int]$AgentTimeoutMinutes = 30,
    [switch]$AllowDirty,
    [switch]$FullValidation,
    [switch]$CheckConfig,
    [ValidateSet('', 'pass', 'fail-then-pass', 'always-fail', 'bad-json', 'escalate-lead', 'repeat-finding', 'escalate-implementer', 'canary-edit', 'canary-delete')][string]$Mock = ''
)

# ------------------------------------------------------------------ model defaults
# Edit here to change the defaults; environment variables and parameters override them.
# Checked against 'agy models' and 'codex debug models' on 2026-09-18.
$DefaultConfig = [ordered]@{
    AgyModel            = 'gemini-3.8-flash'   # normal implementer: Flash, balanced effort
    AgyEffort           = 'medium'
    AgyEscalationModel  = 'gemini-3.1-pro'     # used only after Codex recommends escalate_implementer
    AgyEscalationEffort = 'high'
    CodexModel          = 'gpt-6-astra'        # the auditor is the quality gate: strongest model ...
    CodexEffort         = 'medium'             # ... at balanced effort (not high/xhigh/max for every task)
}
$LeadCategories = @('architecture', 'concurrency', 'data-corruption', 'ambiguous-requirement')
$PipelineVersion = '1.0.0'
# Always protected (the pipeline's own files); projects add theirs in .ai/protected-paths.txt.
$BuiltinProtected = @('scripts/ai-pipeline.ps1', '.ai/prompts/*', '.ai/review.schema.json', '.ai/validate.ps1',
    '.ai/checks.ps1', '.ai/protected-paths.txt', '.ai/context-ignore.txt', '.ai/required-anchors.txt', '.ai/plan.md',
    '.ai/README.md', '.ai/.gitignore', '.ai/pipeline-version.txt', 'AGENTS.md', 'GEMINI.md', 'CLAUDE.md')

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $Utf8 } catch { }   # decode git/agent output as UTF-8

# ------------------------------------------------------------------ helpers

function Protect-Secrets([string]$Text) {
    if (-not $Text) { return $Text }
    $t = $Text
    $t = $t -replace 'sk-[A-Za-z0-9_\-]{16,}', 'sk-***REDACTED***'
    $t = $t -replace 'AIza[0-9A-Za-z_\-]{30,}', 'AIza***REDACTED***'
    $t = $t -replace 'ya29\.[0-9A-Za-z_\-\.]{20,}', 'ya29.***REDACTED***'
    $t = $t -replace 'gh[pousr]_[A-Za-z0-9]{20,}', 'gh*_***REDACTED***'
    $t = $t -replace '(?i)(bearer\s+)[A-Za-z0-9\._\-]{16,}', '$1***REDACTED***'
    $t = $t -replace '(?i)("?(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)"?\s*[:=]\s*"?)[^\s",]{8,}', '$1***REDACTED***'
    return $t
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Read-Utf8([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [IO.File]::ReadAllText($Path, $Utf8)
}

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, (Protect-Secrets $Message)
    Write-Host $line
    if ($script:LogFile) { [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $Utf8) }
}

function ConvertTo-CommandLineArg([string]$Arg) {
    # Windows CommandLineToArgvW quoting, so paths with spaces survive Start-Process
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $bs = [char]92
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $n = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq $bs) { $n++; continue }
        if ($ch -eq '"') { [void]$sb.Append($bs, 2 * $n + 1); [void]$sb.Append('"'); $n = 0; continue }
        if ($n -gt 0) { [void]$sb.Append($bs, $n); $n = 0 }
        [void]$sb.Append($ch)
    }
    if ($n -gt 0) { [void]$sb.Append($bs, 2 * $n) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Tool {
    # Runs an executable with redirected output, no stdin, and a hard timeout (kills the process tree).
    param([string]$Exe, [string[]]$ArgList, [string]$StdoutPath, [string]$StderrPath, [int]$TimeoutSec)
    $cmdLine = ($ArgList | ForEach-Object { ConvertTo-CommandLineArg $_ }) -join ' '
    $p = Start-Process -FilePath $Exe -ArgumentList $cmdLine -WorkingDirectory $script:Root -NoNewWindow -PassThru `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -RedirectStandardInput $script:EmptyFile
    $null = $p.Handle   # keeps ExitCode readable in Windows PowerShell 5.1
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        $p.WaitForExit()
        return @{ ExitCode = -1; TimedOut = $true }
    }
    $p.WaitForExit()
    foreach ($f in @($StdoutPath, $StderrPath)) {
        if (Test-Path -LiteralPath $f) { Write-Utf8 $f (Protect-Secrets (Read-Utf8 $f)) }
    }
    return @{ ExitCode = $p.ExitCode; TimedOut = $false }
}

function Invoke-Git {
    param([string[]]$GitArgs, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git -c core.quotepath=off -C $script:Root @GitArgs 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($null -eq $out) { $out = @() }   # no output: avoid @($null) having Count 1
    $stdout = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $stderr = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($code -ne 0 -and -not $AllowFail) { throw ('git {0} failed ({1}): {2}' -f ($GitArgs -join ' '), $code, ($stderr -join ' ')) }
    return , $stdout
}

function New-Snapshot([string]$Label) {
    # Tree object of the whole working tree (tracked + untracked, .gitignore respected),
    # built in a temporary copy of the index so the user's staging area is never modified.
    $idx = Join-Path $script:RunDir "index.$Label.tmp"
    $real = Join-Path $script:GitDir 'index'
    if (Test-Path -LiteralPath $real) { Copy-Item -LiteralPath $real -Destination $idx -Force }
    $old = $env:GIT_INDEX_FILE
    $env:GIT_INDEX_FILE = $idx
    try {
        # .ai/.gitignore keeps .ai/logs and .ai/review.json out (an explicit exclude of an ignored path makes git add fail)
        [void](Invoke-Git @('add', '-A', '--', '.'))
        $tree = (Invoke-Git @('write-tree'))[0].Trim()
    } finally {
        if ($old) { $env:GIT_INDEX_FILE = $old } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $idx -Force -ErrorAction SilentlyContinue
    }
    return $tree
}

function Resolve-Exe([string]$EnvName, [string]$CmdName, [string[]]$Fallbacks) {
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv -and (Test-Path -LiteralPath $fromEnv)) { return $fromEnv }
    $cmd = Get-Command $CmdName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($f in $Fallbacks) { if ($f -and (Test-Path -LiteralPath $f)) { return $f } }
    return $null
}

function New-Finding([string]$Severity, [string]$Category, [string]$Issue, [string]$Reasoning, [string]$Fix) {
    return [pscustomobject][ordered]@{
        severity = $Severity; category = $Category; persists = $false; file = '(pipeline)'; line = ''
        issue = $Issue; reasoning = $Reasoning; suggested_fix = $Fix
    }
}

function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

function Get-RelPath([string]$Abs) {
    return $Abs.Substring($script:Root.Length).TrimStart('\').Replace('\', '/')
}

# ------------------------------------------------------------------ model configuration

function Get-Setting([string]$ParamValue, [string]$EnvName, [string]$Default) {
    if ($ParamValue) { return @{ Value = $ParamValue.Trim(); Source = 'parameter' } }
    $e = [Environment]::GetEnvironmentVariable($EnvName)
    if ($e) { return @{ Value = $e.Trim(); Source = "env $EnvName" } }
    return @{ Value = $Default; Source = 'default' }
}

function Resolve-ToolExes {
    $extDir = Join-Path $env:USERPROFILE '.vscode\extensions'
    $codexFallback = @()
    if (Test-Path -LiteralPath $extDir) {
        $codexFallback = @(Get-ChildItem -LiteralPath $extDir -Directory -Filter 'openai.chatgpt-*' |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\windows-x86_64\codex.exe' })
    }
    $script:AgyExe = Resolve-Exe 'AI_AGY_EXE' 'agy' @((Join-Path $env:USERPROFILE '.gemini\bin\agy.exe'))
    $script:CodexExe = Resolve-Exe 'AI_CODEX_EXE' 'codex' $codexFallback
    if (-not $script:AgyExe) { throw 'agy (Antigravity CLI) not found; set AI_AGY_EXE' }
    if (-not $script:CodexExe) { throw 'codex not found; set AI_CODEX_EXE' }
}

function Invoke-Capture([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 120) {
    # Runs a short query command and returns its stdout text.
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        $r = Invoke-Tool -Exe $Exe -ArgList $ArgList -StdoutPath $o -StderrPath $e -TimeoutSec $TimeoutSec
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            throw ('{0} {1} failed (exit {2}): {3}' -f (Split-Path $Exe -Leaf), ($ArgList -join ' '), $r.ExitCode, ((Read-Utf8 $e).Trim()))
        }
        return (Read-Utf8 $o)
    } finally { Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue }
}

function Get-AgyCatalog {
    # 'agy models' prints: <id><TAB><display label>
    $cat = [ordered]@{}
    foreach ($line in ((Invoke-Capture $script:AgyExe @('models')) -split "`r?`n")) {
        $m = [regex]::Match($line, '^(\S+)\t(.+)$')
        if ($m.Success) { $cat[$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
    }
    if ($cat.Count -eq 0) { throw "'agy models' returned no models (not logged in?)" }
    return $cat
}

function Get-CodexCatalog {
    # 'codex debug models' prints the model catalog as JSON: models[].slug, supported_reasoning_levels[].effort
    $j = (Invoke-Capture $script:CodexExe @('debug', 'models')) | ConvertFrom-Json
    $cat = [ordered]@{}
    foreach ($m in @($j.models)) { $cat[[string]$m.slug] = @($m.supported_reasoning_levels | ForEach-Object { [string]$_.effort }) }
    if ($cat.Count -eq 0) { throw "'codex debug models' returned no models" }
    return $cat
}

function Resolve-AgyId([string]$Model, [string]$Effort, $Catalog, [string]$What) {
    # Returns the exact catalog id to pass to --model. Throws instead of falling back.
    if ($Effort -eq 'none') { $Effort = '' }
    if ($Effort -and $Effort -notin @('low', 'medium', 'high')) { throw "$What effort '$Effort' is invalid (agy: low|medium|high|none)" }
    $suffix = [regex]::Match($Model, '-(low|medium|high)$')
    if ($suffix.Success) {
        if ($Effort -and $Effort -ne $suffix.Groups[1].Value) { throw "$What model '$Model' already contains effort '$($suffix.Groups[1].Value)', which conflicts with effort '$Effort'" }
        $id = $Model
    } elseif ($Effort) { $id = "$Model-$Effort" } else { $id = $Model }
    if ($null -ne $Catalog -and -not $Catalog.Contains($id)) {
        throw ("$What model '$id' is not in 'agy models'. Available: " + (@($Catalog.Keys) -join ', '))
    }
    return $id
}

function Resolve-ModelConfig([switch]$Validate) {
    # Fills $script:Cfg. With -Validate, checks every model against the CLIs' own catalogs (fail fast).
    $s = [ordered]@{
        AgyModel            = Get-Setting $AgyModel 'AI_AGY_MODEL' $DefaultConfig.AgyModel
        AgyEffort           = Get-Setting $AgyEffort 'AI_AGY_EFFORT' $DefaultConfig.AgyEffort
        AgyEscalationModel  = Get-Setting '' 'AI_AGY_ESCALATION_MODEL' $DefaultConfig.AgyEscalationModel
        AgyEscalationEffort = Get-Setting '' 'AI_AGY_ESCALATION_EFFORT' $DefaultConfig.AgyEscalationEffort
        CodexModel          = Get-Setting $CodexModel 'AI_CODEX_MODEL' $DefaultConfig.CodexModel
        CodexEffort         = Get-Setting $CodexEffort 'AI_CODEX_EFFORT' $DefaultConfig.CodexEffort
    }
    # A full catalog id such as gemini-3.8-flash-low carries its own effort; the default effort must not conflict with it.
    foreach ($pair in @(@('AgyModel', 'AgyEffort'), @('AgyEscalationModel', 'AgyEscalationEffort'))) {
        $sfx = [regex]::Match($s[$pair[0]].Value, '-(low|medium|high)$')
        if ($sfx.Success -and $s[$pair[1]].Source -eq 'default') { $s[$pair[1]] = @{ Value = $sfx.Groups[1].Value; Source = 'model id' } }
    }
    $agyCat = $null; $codexCat = $null
    if ($Validate) { $agyCat = Get-AgyCatalog; $codexCat = Get-CodexCatalog }
    $normalId = Resolve-AgyId $s.AgyModel.Value $s.AgyEffort.Value $agyCat 'AGY'
    $escId = Resolve-AgyId $s.AgyEscalationModel.Value $s.AgyEscalationEffort.Value $agyCat 'AGY escalation'
    $cm = $s.CodexModel.Value; $ce = $s.CodexEffort.Value
    if (-not $cm -or -not $ce) { throw 'Codex model and effort must both be set (no implicit default)' }
    if ($Validate) {
        if (-not $codexCat.Contains($cm)) { throw ("Codex model '$cm' is not in 'codex debug models'. Available: " + (@($codexCat.Keys) -join ', ')) }
        if ($codexCat[$cm] -notcontains $ce) { throw ("Codex effort '$ce' is not supported by '$cm'. Supported: " + ($codexCat[$cm] -join ', ')) }
    }
    $label = { param($id) if ($agyCat) { $agyCat[$id] } else { 'unavailable (not validated)' } }
    $script:Cfg = [ordered]@{
        Validated    = [bool]$Validate
        AgyNormal    = [ordered]@{ Id = $normalId; Model = $s.AgyModel.Value; Effort = $s.AgyEffort.Value; Label = (& $label $normalId); Source = "$($s.AgyModel.Source) / $($s.AgyEffort.Source)" }
        AgyEscalated = [ordered]@{ Id = $escId; Model = $s.AgyEscalationModel.Value; Effort = $s.AgyEscalationEffort.Value; Label = (& $label $escId); Source = "$($s.AgyEscalationModel.Source) / $($s.AgyEscalationEffort.Source)" }
        Codex        = [ordered]@{ Model = $cm; Effort = $ce; Source = "$($s.CodexModel.Source) / $($s.CodexEffort.Source)" }
    }
    $script:AgyActive = $script:Cfg.AgyNormal
}

function Format-ModelConfig {
    $c = $script:Cfg
    $v = if ($c.Validated) { 'validated against agy models / codex debug models' } else { 'NOT validated (mock)' }
    return @(
        "agy normal:     $($c.AgyNormal.Id)  [$($c.AgyNormal.Label)]  (model=$($c.AgyNormal.Model) effort=$($c.AgyNormal.Effort); from $($c.AgyNormal.Source))",
        "agy escalation: $($c.AgyEscalated.Id)  [$($c.AgyEscalated.Label)]  (from $($c.AgyEscalated.Source))",
        "codex:          $($c.Codex.Model)  reasoning effort=$($c.Codex.Effort)  (from $($c.Codex.Source))",
        "config:         $v")
}

function Add-Usage([string]$Agent, [int]$Round, [string]$Model, [string]$Effort, [string]$Resolved, $In, $Out, $Think, $Cache, $Total, [string]$Note = '') {
    # $null means the CLI did not report that number (shown as N/A, never estimated).
    $script:Usage += [pscustomobject][ordered]@{
        agent = $Agent; round = $Round; requested_model = $Model; effort = $Effort
        cli_resolved_model = $Resolved; actual_model = 'unavailable'
        input = $In; output = $Out; thinking = $Think; cache_read = $Cache; total = $Total; note = $Note
    }
}

# ------------------------------------------------------------------ agents

function Invoke-Implementer([int]$Round, [string]$RoundDir, [string]$PrevValidationRel) {
    $report = Join-Path $RoundDir 'agent-report.txt'
    $a = $script:AgyActive
    if ($Mock) {
        # canary-* scenarios touch only mock-canary.txt, to exercise the protected-path and deletion checks
        $canary = Join-Path $script:Root 'mock-canary.txt'
        $what = 'No files changed.'
        if ($Mock -eq 'canary-edit' -and (Test-Path -LiteralPath $canary)) { [IO.File]::AppendAllText($canary, "mock edit round $Round`n", $Utf8); $what = 'Appended to mock-canary.txt.' }
        if ($Mock -eq 'canary-delete' -and (Test-Path -LiteralPath $canary)) { [IO.File]::Delete($canary); $what = 'Deleted mock-canary.txt.' }
        Write-Utf8 $report "MOCK implementer, round $Round, model $($a.Id). $what"
        Add-Usage 'agy' $Round $a.Id $a.Effort 'mock' $null $null $null $null $null 'mock run'
        return $true
    }
    if ($Round -eq 1) {
        $prompt = "You are the IMPLEMENTER in an automated pipeline, round 1 of $MaxRounds. Repository root: $script:Root . " +
            'Follow .ai/prompts/implement.md exactly. The task and plan are in .ai/plan.md. You have no shell access; use file tools only.'
    } else {
        $prompt = "You are the IMPLEMENTER in an automated pipeline, fix round $Round of $MaxRounds. Repository root: $script:Root . " +
            'Follow .ai/prompts/fix.md exactly. Findings to fix: .ai/review.json . Plan: .ai/plan.md . ' +
            "Validation log of the previous round: $PrevValidationRel . You have no shell access; use file tools only."
    }
    $prompt += $script:ContextIgnoreText
    # The catalog id already encodes the effort (e.g. gemini-3.8-flash-medium), so --effort is not passed.
    # agy's own debug log (temp file, deleted after use) records which model the CLI resolved.
    $agyLog = [IO.Path]::GetTempFileName()
    $argList = @('-p', $prompt, '--add-dir', $script:Root, '--mode', 'accept-edits',
        '--output-format', 'json', '--print-timeout', "$($AgentTimeoutMinutes)m",
        '--model', $a.Id, '--log-file', $agyLog)
    $out = Join-Path $RoundDir 'agy.stdout.txt'
    $err = Join-Path $RoundDir 'agy.stderr.txt'
    Write-Log "agy ($($a.Id)) round $Round started"
    try {
        $r = Invoke-Tool -Exe $script:AgyExe -ArgList $argList -StdoutPath $out -StderrPath $err -TimeoutSec ($AgentTimeoutMinutes * 60 + 120)
        $resolved = 'unavailable'
        $hits = [regex]::Matches((Read-Utf8 $agyLog), 'selected model override to backend: label="([^"]+)"')
        if ($hits.Count -gt 0) { $resolved = $hits[$hits.Count - 1].Groups[1].Value }
    } finally { Remove-Item -LiteralPath $agyLog -Force -ErrorAction SilentlyContinue }
    if ($r.TimedOut) { Write-Log "agy timed out after $AgentTimeoutMinutes min" 'ERROR'; return $false }

    # agy exits 0 even when a tool was auto-denied, so the JSON result is what counts.
    $json = $null
    $lines = (Read-Utf8 $out) -split "`r?`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].TrimStart().StartsWith('{')) {
            try { $json = $lines[$i] | ConvertFrom-Json; break } catch { }
        }
    }
    if (-not $json) { Write-Log "agy returned no JSON result (exit $($r.ExitCode)); see $out" 'ERROR'; return $false }
    $status = Get-Prop $json 'status'
    $response = [string](Get-Prop $json 'response')
    $denied = @()
    $dp = $json.PSObject.Properties['denied_actions']
    if ($dp -and $null -ne $dp.Value) { $denied = @($dp.Value) }
    $u = Get-Prop $json 'usage'
    Add-Usage 'agy' $Round $a.Id $a.Effort $resolved (Get-Prop $u 'input_tokens') (Get-Prop $u 'output_tokens') `
        (Get-Prop $u 'thinking_tokens') (Get-Prop $u 'cache_read_tokens') (Get-Prop $u 'total_tokens')
    if ($status -ne 'SUCCESS') { Write-Log ("agy status '$status': " + [string](Get-Prop $json 'error')) 'ERROR'; return $false }
    if ($resolved -eq 'unavailable') { Write-Log 'agy log did not show the resolved model; recorded as unavailable' 'WARN' }
    elseif ($script:Cfg.Validated -and $resolved -ne $a.Label) {
        Write-Log "agy resolved model '$resolved' but '$($a.Label)' ($($a.Id)) was requested" 'ERROR'; return $false
    }
    $text = "agy status: $status`r`nconversation_id: $(Get-Prop $json 'conversation_id')`r`n"
    if ($denied.Count -gt 0) {
        $names = ($denied | ForEach-Object { '{0}/{1}' -f (Get-Prop $_ 'action'), (Get-Prop $_ 'display_name') }) -join ', '
        $text += "DENIED ACTIONS (headless mode has no permission for these): $names`r`n"
        Write-Log "agy had denied actions: $names (the agent may have stopped early)" 'WARN'
    }
    $text += "`r`n--- implementer report ---`r`n$response`r`n"
    Write-Utf8 $report (Protect-Secrets $text)
    if (-not $response.Trim()) { Write-Log 'agy produced an empty report' 'WARN' }
    Write-Log "agy round $Round finished"
    return $true
}

function Invoke-Auditor([int]$Round, [string]$RoundDir, [string]$OutPath) {
    $c = $script:Cfg.Codex
    if ($Mock) {
        Add-Usage 'codex' $Round $c.Model $c.Effort 'mock' $null $null $null $null $null 'mock run'
        if ($Mock -eq 'bad-json') { Write-Utf8 $OutPath 'this is not json'; return $true }
        $fail = ($Mock -in @('always-fail', 'repeat-finding', 'escalate-lead')) -or ($Mock -in @('fail-then-pass', 'escalate-implementer') -and $Round -eq 1)
        $cat = 'correctness'; $issue = "mock finding round $Round"; $rec = 'fix'
        if ($Mock -eq 'escalate-lead') { $cat = 'architecture' }
        if ($Mock -eq 'repeat-finding') { $issue = 'mock finding that is never fixed' }
        if ($Mock -eq 'escalate-implementer') { $rec = 'escalate_implementer' }
        $major = @()
        if ($fail) { $major = @([ordered]@{ severity = 'major'; category = $cat; persists = ($Mock -eq 'repeat-finding' -and $Round -gt 1); file = 'mock.txt'; line = '1'; issue = $issue; reasoning = 'mock'; suggested_fix = 'mock fix' }) }
        $obj = [ordered]@{ status = $(if ($fail) { 'FAIL' } else { 'PASS' }); summary = "MOCK audit round $Round"; recommendation = $(if ($fail) { $rec } else { 'accept' })
            critical = @(); major = $major; minor = @(); tests = [ordered]@{ status = 'NOT_RUN'; notes = @('mock') } }
        Write-Utf8 $OutPath ($obj | ConvertTo-Json -Depth 10)
        return $true
    }
    $rel = Get-RelPath $RoundDir
    if ($Round -eq 1) {
        $prompt = "You are the INDEPENDENT AUDITOR, round 1 of $MaxRounds (full review of the change). Follow .ai/prompts/audit.md exactly. Plan: .ai/plan.md . " +
            "Round files, relative to the repository root: $rel/diff-cumulative.patch , $rel/changed-files.txt , $rel/validation.txt , $rel/agent-report.txt . "
    } else {
        $prompt = "You are the INDEPENDENT AUDITOR, round $Round of ${MaxRounds}: TARGETED RE-REVIEW (see 'Round 2 and later' in .ai/prompts/audit.md; follow that file exactly). " +
            "Previous review: $rel/previous-review.json . What the implementer changed in this fix round: $rel/diff-round.patch . " +
            "Also available if needed: $rel/diff-cumulative.patch , $rel/changed-files.txt , $rel/validation.txt , $rel/agent-report.txt , plan .ai/plan.md . "
    }
    $prompt += 'You are in a read-only sandbox: do not modify any file. Reply only with the JSON required by the schema.'
    $prompt += $script:ContextIgnoreText
    # Model and effort are pinned so ~/.codex/config.toml defaults never apply silently.
    # --json prints JSONL events; turn.completed carries the token usage. -o still gets the final message.
    $argList = @('exec', '-C', $script:Root, '-s', 'read-only', '--ephemeral', '--color', 'never', '--json',
        '-m', $c.Model, '-c', ('model_reasoning_effort="{0}"' -f $c.Effort),
        '--output-schema', $script:SchemaPath, '-o', $OutPath, $prompt)
    $out = Join-Path $RoundDir 'codex.stdout.jsonl'
    $err = Join-Path $RoundDir 'codex.stderr.txt'
    Write-Log "codex ($($c.Model), effort $($c.Effort)) audit round $Round started"
    $r = Invoke-Tool -Exe $script:CodexExe -ArgList $argList -StdoutPath $out -StderrPath $err -TimeoutSec ($AgentTimeoutMinutes * 60)
    if ($r.TimedOut) { Write-Log "codex timed out after $AgentTimeoutMinutes min" 'ERROR'; return $false }

    $sum = @{}; $errMsg = ''
    foreach ($line in ((Read-Utf8 $out) -split "`r?`n")) {
        if (-not $line.StartsWith('{')) { continue }
        try { $ev = $line | ConvertFrom-Json } catch { continue }
        $t = Get-Prop $ev 'type'
        if ($t -eq 'turn.completed') {
            $u = Get-Prop $ev 'usage'
            foreach ($k in 'input_tokens', 'output_tokens', 'reasoning_output_tokens', 'cached_input_tokens') {
                $v = Get-Prop $u $k
                if ($null -ne $v) { $sum[$k] = [long]$sum[$k] + [long]$v }
            }
        } elseif ($t -eq 'error' -or $t -eq 'turn.failed') {
            $errMsg = [string](Get-Prop $ev 'message'); if (-not $errMsg) { $errMsg = [string](Get-Prop (Get-Prop $ev 'error') 'message') }
        }
    }
    # Codex reports no total. OpenAI usage semantics: cached is part of input, reasoning part of output.
    $in = $sum['input_tokens']; $o = $sum['output_tokens']
    $tot = $null; if ($null -ne $in -and $null -ne $o) { $tot = $in + $o }
    Add-Usage 'codex' $Round $c.Model $c.Effort 'unavailable' $in $o $sum['reasoning_output_tokens'] $sum['cached_input_tokens'] $tot 'total = input + output (computed)'
    if ($r.ExitCode -ne 0) {
        $short = ($errMsg -replace '\s+', ' '); if ($short.Length -gt 300) { $short = $short.Substring(0, 300) }
        Write-Log "codex exit $($r.ExitCode): $short (see $out)" 'ERROR'; return $false
    }
    Write-Log "codex audit round $Round finished"
    return $true
}

function Get-FindingKey($F) {
    return ('{0}|{1}' -f $F.file, ($F.issue -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Get-Escalation($Review, [int]$Round, [string[]]$PrevBlockingKeys) {
    # Returns @{ Lead = reasons that stop the loop; Implementer = $true to switch to the stronger agy model }
    $blocking = @($Review.critical) + @($Review.major)
    $lead = @()
    foreach ($f in $blocking) {
        $cat = [string]$f.category
        if ($LeadCategories -contains $cat) { $lead += "blocking '$cat' finding: $($f.file) - $($f.issue)" }
        elseif ($cat -eq 'security' -and $f.severity -eq 'critical') { $lead += "critical security finding: $($f.file) - $($f.issue)" }
        if ($Round -gt 1 -and (($f.persists -eq $true) -or ($PrevBlockingKeys -contains (Get-FindingKey $f)))) {
            $lead += "same blocking finding in rounds $($Round - 1) and ${Round}: $($f.file) - $($f.issue)"
        }
    }
    if ($Review.recommendation -eq 'escalate_lead') { $lead += 'Codex recommends escalate_lead' }
    return @{ Lead = $lead; Implementer = ($Review.recommendation -eq 'escalate_implementer') }
}

function Read-Review([string]$Path) {
    # Returns the parsed review or $null if it is missing/invalid.
    $raw = Read-Utf8 $Path
    if (-not $raw.Trim()) { return $null }
    try { $rv = $raw | ConvertFrom-Json } catch { return $null }
    $st = Get-Prop $rv 'status'
    if ($st -ne 'PASS' -and $st -ne 'FAIL') { return $null }
    foreach ($k in 'critical', 'major', 'minor') {
        # read the property directly: returning an empty array from a function unrolls it to $null
        $prop = $rv.PSObject.Properties[$k]
        if (-not $prop -or $null -eq $prop.Value) { return $null }
        $rv.$k = @($prop.Value)
    }
    if ($null -eq (Get-Prop $rv 'summary')) { return $null }
    if (-not (Get-Prop $rv 'recommendation')) {
        $rv | Add-Member -NotePropertyName recommendation -NotePropertyValue $(if ($st -eq 'PASS') { 'accept' } else { 'fix' }) -Force
    }
    foreach ($f in (@($rv.critical) + @($rv.major) + @($rv.minor))) {
        if ($null -eq $f) { continue }
        if (-not (Get-Prop $f 'category')) { $f | Add-Member -NotePropertyName category -NotePropertyValue 'other' -Force }
        if ($null -eq (Get-Prop $f 'persists')) { $f | Add-Member -NotePropertyName persists -NotePropertyValue $false -Force }
    }
    if ($null -eq (Get-Prop $rv 'tests')) { $rv | Add-Member -NotePropertyName tests -NotePropertyValue ([pscustomobject]@{ status = 'NOT_RUN'; notes = @() }) }
    return $rv
}

# ------------------------------------------------------------------ setup

$script:LogFile = $null
if (-not $RepoRoot) { $RepoRoot = Join-Path $PSScriptRoot '..' }
if (-not (Test-Path -LiteralPath $RepoRoot)) { Write-Host "RepoRoot not found: $RepoRoot"; exit 2 }
$script:Root = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath.TrimEnd('\')

try {
    $top = (Invoke-Git @('rev-parse', '--show-toplevel'))[0]
    $script:GitDir = (Invoke-Git @('rev-parse', '--absolute-git-dir'))[0]
} catch { Write-Host "Not a git repository: $script:Root"; exit 2 }
$script:Root = (Resolve-Path -LiteralPath $top).ProviderPath.TrimEnd('\')
$script:Usage = @()
$script:EmptyFile = [IO.Path]::GetTempFileName()   # empty stdin for every child process

if ($CheckConfig) {
    $code = 0
    try {
        Resolve-ToolExes
        Write-Host "agy:   $script:AgyExe"
        Write-Host "codex: $script:CodexExe"
        Resolve-ModelConfig -Validate
        Format-ModelConfig | ForEach-Object { Write-Host $_ }
        Write-Host 'CONFIG_STATUS=OK'
    } catch { Write-Host ("CONFIG_STATUS=ERROR " + (Protect-Secrets $_.Exception.Message)); $code = 2 }
    Remove-Item -LiteralPath $script:EmptyFile -Force -ErrorAction SilentlyContinue
    exit $code
}

$aiDir = Join-Path $script:Root '.ai'
$planPath = Join-Path $aiDir 'plan.md'
$script:SchemaPath = Join-Path $aiDir 'review.schema.json'
$reviewPath = Join-Path $aiDir 'review.json'
$validateScript = Join-Path $aiDir 'validate.ps1'
$protectedFile = Join-Path $aiDir 'protected-paths.txt'

# Paths agents should not read (appended to every agent prompt). Always: .git and other runs' logs.
$ignore = @('.git/', '.ai/logs/ (except the round files named above)')
$ignoreFile = Join-Path $aiDir 'context-ignore.txt'
if (Test-Path -LiteralPath $ignoreFile) {
    $ignore += @([IO.File]::ReadAllLines($ignoreFile, $Utf8) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
$script:ContextIgnoreText = ' Reading scope: do not open, list or search these unless the plan points there: ' + ($ignore -join ', ') +
    ' ; never read binary files.'
foreach ($f in @($planPath, $script:SchemaPath, (Join-Path $aiDir '.gitignore'), (Join-Path $aiDir 'prompts\implement.md'), (Join-Path $aiDir 'prompts\fix.md'), (Join-Path $aiDir 'prompts\audit.md'))) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "Missing required file: $f"; exit 2 }
}
if ((Read-Utf8 $planPath) -match '\(one paragraph: what the user asked for\)') {
    Write-Host '.ai/plan.md is still the template. Claude must write the plan first.'; exit 2
}

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$n = 1
while (Test-Path -LiteralPath (Join-Path $aiDir "logs\$runId")) { $n++; $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$n" }
$script:RunDir = Join-Path $aiDir "logs\$runId"
New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
$script:LogFile = Join-Path $script:RunDir 'pipeline.log'

$lockPath = Join-Path $aiDir 'logs\.lock'
try { $lock = [IO.File]::Open($lockPath, 'CreateNew', 'Write', 'None') }
catch { Write-Host "Another pipeline run holds $lockPath (delete it if no run is active)."; exit 2 }

function Invoke-Pipeline {
    Write-Log "ai-pipeline $PipelineVersion  run $runId  root: $script:Root  mock: '$Mock'  maxRounds: $MaxRounds"
    Copy-Item -LiteralPath $planPath -Destination (Join-Path $script:RunDir 'plan.md')

    # Models: explicit, validated against the CLIs' catalogs before any agent runs; no fallback.
    try {
        if (-not $Mock) {
            Resolve-ToolExes
            Write-Log "agy:   $script:AgyExe"
            Write-Log "codex: $script:CodexExe"
            Resolve-ModelConfig -Validate
        } else { Resolve-ModelConfig }
    } catch { Write-Log "model configuration error: $($_.Exception.Message)" 'ERROR'; $script:ExitCode = 2; return }
    Format-ModelConfig | ForEach-Object { Write-Log $_ }

    # Safety: the user's uncommitted work is preserved, but we say so loudly.
    $dirty = Invoke-Git @('status', '--porcelain', '--untracked-files=all', '--', '.', ':(exclude).ai')
    if ($dirty.Count -gt 0) {
        Write-Log ("working tree has {0} uncommitted/untracked entries (outside .ai/)" -f $dirty.Count) 'WARN'
        if (-not $AllowDirty) {
            Write-Log 'Refusing to start. Commit your work first, or re-run with -AllowDirty (changes are kept; a baseline snapshot is recorded).' 'ERROR'
            $script:ExitCode = 2; return
        }
    }
    $base = New-Snapshot 'base'
    Write-Log "baseline tree: $base  (view changes later: git diff $base <tree>)"

    $protected = @($BuiltinProtected)
    if (Test-Path -LiteralPath $protectedFile) {
        $protected += @([IO.File]::ReadAllLines($protectedFile, $Utf8) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    $final = $null
    $prevValidationRel = ''
    $roundsDone = 0
    $prevTree = $base
    $prevBlockingKeys = @()
    $escalations = @()
    $leadReasons = @()
    $agentError = $false
    for ($round = 1; $round -le $MaxRounds; $round++) {
        $roundDir = Join-Path $script:RunDir "round-$round"
        New-Item -ItemType Directory -Force -Path $roundDir | Out-Null
        Write-Log "===== round $round / $MaxRounds ====="

        if (-not (Invoke-Implementer $round $roundDir $prevValidationRel)) { $agentError = $true; break }

        # Diff against the baseline, and against the previous round (what this fix round changed)
        $after = New-Snapshot "r$round"
        $nameStatus = Invoke-Git @('diff', '--name-status', '--no-renames', $base, $after)
        $changedPath = Join-Path $roundDir 'changed-files.txt'
        Write-Utf8 $changedPath (($nameStatus -join "`n") + "`n")
        $patch = Invoke-Git @('diff', '--no-color', '--no-renames', $base, $after)
        Write-Utf8 (Join-Path $roundDir 'diff-cumulative.patch') (($patch -join "`n") + "`n")
        Write-Log ("changed files since baseline: {0} (tree {1})" -f $nameStatus.Count, $after)
        if ($round -gt 1) {
            $roundPatch = Invoke-Git @('diff', '--no-color', '--no-renames', $prevTree, $after)
            Write-Utf8 (Join-Path $roundDir 'diff-round.patch') (($roundPatch -join "`n") + "`n")
            Copy-Item -LiteralPath (Join-Path $script:RunDir "round-$($round - 1)\review.json") -Destination (Join-Path $roundDir 'previous-review.json')
            if ($prevTree -eq $after) { Write-Log 'implementer changed nothing in this fix round' 'WARN' }
        } elseif ($nameStatus.Count -eq 0) { Write-Log 'implementer made no changes' 'WARN' }
        $prevTree = $after

        $pipelineFindings = @()
        foreach ($entry in $nameStatus) {
            $parts = $entry -split "`t"
            $st = $parts[0]; $path = $parts[-1]
            if ($st -like 'D*') {
                $pipelineFindings += New-Finding 'critical' 'scope' "File deleted: $path" 'The pipeline forbids deleting files.' "Restore it: git restore --source=$base -- `"$path`" (run by a human)."
            }
            foreach ($pat in $protected) {
                if ($path -like $pat) {
                    $pipelineFindings += New-Finding 'critical' 'scope' "Protected path changed: $path" "Matches '$pat' in .ai/protected-paths.txt." 'Revert this file to its baseline content and make the change elsewhere, or ask the lead to adjust the plan.'
                    break
                }
            }
        }

        # Validation
        $valLog = Join-Path $roundDir 'validation.txt'
        $valStatus = 'NOT_RUN'
        if (Test-Path -LiteralPath $validateScript) {
            $vArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $validateScript, '-Root', $script:Root, '-ChangedFilesPath', $changedPath)
            if ($FullValidation) { $vArgs += '-Full' }
            $vr = Invoke-Tool -Exe (Join-Path $PSHOME 'powershell.exe') -ArgList $vArgs -StdoutPath $valLog -StderrPath (Join-Path $roundDir 'validation.stderr.txt') -TimeoutSec 1800
            $m = [regex]::Match((Read-Utf8 $valLog), 'VALIDATION_STATUS=(PASS|FAIL|NOT_RUN)')
            if ($vr.TimedOut) { $valStatus = 'FAIL'; [IO.File]::AppendAllText($valLog, "`nvalidation timed out`n", $Utf8) }
            elseif ($m.Success) { $valStatus = $m.Groups[1].Value }
            elseif ($vr.ExitCode -ne 0) { $valStatus = 'FAIL' }
        } else {
            Write-Utf8 $valLog "No .ai/validate.ps1 in this repository.`nVALIDATION_STATUS=NOT_RUN`n"
        }
        $prevValidationRel = Get-RelPath $valLog
        Write-Log "validation: $valStatus"
        if ($valStatus -eq 'FAIL') {
            $pipelineFindings += New-Finding 'critical' 'validation' 'Validation failed' "See $prevValidationRel (FAIL lines)." 'Fix every FAIL line reported in the validation log.'
        }

        # Audit
        $codexOut = Join-Path $roundDir 'review.codex.json'
        if (-not (Invoke-Auditor $round $roundDir $codexOut)) { $agentError = $true; break }
        $review = Read-Review $codexOut
        if (-not $review) { Write-Log "codex output is missing or not valid review JSON: $codexOut" 'ERROR'; $agentError = $true; break }

        $codexStatus = $review.status
        foreach ($pf in $pipelineFindings) { if ($prevBlockingKeys -contains (Get-FindingKey $pf)) { $pf.persists = $true } }
        $review.critical = @($review.critical) + @($pipelineFindings)
        if ($valStatus -eq 'FAIL') { $review.tests.status = 'FAIL' }
        $blocking = $review.critical.Count + $review.major.Count
        if ($blocking -gt 0 -or $codexStatus -eq 'FAIL') { $review.status = 'FAIL' } else { $review.status = 'PASS' }
        if ($codexStatus -eq 'FAIL' -and $blocking -eq 0) { Write-Log 'codex said FAIL without critical/major findings; treated as FAIL' 'WARN' }

        $json = $review | ConvertTo-Json -Depth 10
        Write-Utf8 (Join-Path $roundDir 'review.json') $json
        Write-Utf8 $reviewPath $json
        $roundsDone = $round
        $final = $review
        Write-Log ("round {0}: {1}  critical={2} major={3} minor={4} (pipeline findings: {5}) recommendation={6}" -f $round, $review.status, $review.critical.Count, $review.major.Count, $review.minor.Count, $pipelineFindings.Count, $review.recommendation)
        if ($review.status -eq 'PASS') { break }

        # Escalation: do not burn more rounds on problems another round cannot fix
        $esc = Get-Escalation $review $round $prevBlockingKeys
        if ($esc.Lead.Count -gt 0) {
            $leadReasons = @($esc.Lead)
            $escalations += "round ${round}: escalated to lead (Claude): " + ($leadReasons -join '; ')
            Write-Log "escalating to the lead, stopping: $($leadReasons -join '; ')" 'WARN'
            break
        }
        if ($esc.Implementer -and $round -lt $MaxRounds) {
            if ($script:AgyActive.Id -ne $script:Cfg.AgyEscalated.Id) {
                $escalations += "round ${round}: agy $($script:AgyActive.Id) -> $($script:Cfg.AgyEscalated.Id) (Codex: escalate_implementer)"
                Write-Log "escalating implementer to $($script:Cfg.AgyEscalated.Id) for the next round" 'WARN'
                $script:AgyActive = $script:Cfg.AgyEscalated
            } else { Write-Log 'Codex recommends escalate_implementer, but the escalation model is already in use' 'WARN' }
        }
        $prevBlockingKeys = @((@($review.critical) + @($review.major)) | ForEach-Object { Get-FindingKey $_ })
    }

    if ($agentError) { $script:ExitCode = 3 }
    elseif ($leadReasons.Count -gt 0) { $script:ExitCode = 4 }
    elseif ($final -and $final.status -eq 'PASS') { $script:ExitCode = 0 }
    else { $script:ExitCode = 1 }
    $resultText = @{ 0 = 'PASS'; 1 = 'FAIL (max rounds reached)'; 3 = 'AGENT ERROR'; 4 = 'ESCALATED TO LEAD' }[$script:ExitCode]

    if ($leadReasons.Count -gt 0) {
        $e = "# Escalation to the lead (Claude)`n`nThe pipeline stopped after round $roundsDone because another implementation round is unlikely to help.`n`n## Reasons`n" +
            (($leadReasons | ForEach-Object { "- $_" }) -join "`n") +
            "`n`n## What the lead should do`n- Re-read the findings in .ai/review.json and the diff of the last round.`n- Clarify or redesign the plan (.ai/plan.md), or ask the user to decide; then re-run the pipeline.`n"
        Write-Utf8 (Join-Path $script:RunDir 'escalation.md') (Protect-Secrets $e)
    }

    # Run metadata (machine-readable): what was requested, what the CLI resolved, token usage
    $meta = [ordered]@{
        pipeline_version = $PipelineVersion; run_id = $runId; result = $resultText; exit_code = $script:ExitCode; rounds = $roundsDone; max_rounds = $MaxRounds; mock = $Mock
        models_validated = $script:Cfg.Validated
        agy = [ordered]@{ requested_model = $script:Cfg.AgyNormal.Id; model = $script:Cfg.AgyNormal.Model; effort = $script:Cfg.AgyNormal.Effort; expected_label = $script:Cfg.AgyNormal.Label; source = $script:Cfg.AgyNormal.Source }
        agy_escalation = [ordered]@{ requested_model = $script:Cfg.AgyEscalated.Id; effort = $script:Cfg.AgyEscalated.Effort; expected_label = $script:Cfg.AgyEscalated.Label; source = $script:Cfg.AgyEscalated.Source }
        codex = [ordered]@{ requested_model = $script:Cfg.Codex.Model; reasoning_effort = $script:Cfg.Codex.Effort; actual_model = 'unavailable'; source = $script:Cfg.Codex.Source }
        escalations = $escalations
        usage = $script:Usage
    }
    Write-Utf8 (Join-Path $script:RunDir 'run.json') ($meta | ConvertTo-Json -Depth 6)

    # Summary
    $finalTree = New-Snapshot 'final'
    $changedFinal = Invoke-Git @('diff', '--name-status', '--no-renames', $base, $finalTree)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# ai-pipeline run $runId")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- result: **$resultText** (exit $($script:ExitCode)) after $roundsDone audited round(s) (max $MaxRounds)")
    [void]$sb.AppendLine("- baseline tree: $base ; final tree: $finalTree")
    if ($final) {
        [void]$sb.AppendLine("- summary: $($final.summary)")
        [void]$sb.AppendLine("- tests: $($final.tests.status) ; codex recommendation: $($final.recommendation)")
    }
    if ($leadReasons.Count -gt 0) { [void]$sb.AppendLine('- **escalated to the lead**: see escalation.md') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Changed files')
    if ($changedFinal.Count -eq 0) { [void]$sb.AppendLine('(none)') }
    foreach ($c in $changedFinal) { [void]$sb.AppendLine("- $($c -replace "`t", ' ')") }
    if ($final) {
        foreach ($sev in 'critical', 'major', 'minor') {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("## $sev ($($final.$sev.Count))")
            foreach ($f in $final.$sev) { [void]$sb.AppendLine("- [$($f.category)$(if ($f.persists) { ', persists' })] $($f.file):$($f.line) - $($f.issue)") }
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Run metadata')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Agent | requested_model | effort | cli_resolved_model | actual_model |')
    [void]$sb.AppendLine('|---|---|---|---|---|')
    $seen = @{}
    foreach ($u in $script:Usage) {
        $k = "$($u.agent)|$($u.requested_model)|$($u.cli_resolved_model)"
        if ($seen.ContainsKey($k)) { continue }; $seen[$k] = 1
        [void]$sb.AppendLine("| $($u.agent) | $($u.requested_model) | $($u.effort) | $($u.cli_resolved_model) | $($u.actual_model) |")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Models validated against the CLI catalogs: $($script:Cfg.Validated). cli_resolved_model for agy is the label in agy's own log;")
    [void]$sb.AppendLine('neither CLI returns the model the backend actually served, so actual_model is unavailable.')

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## AI Usage')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Agent | Round | Model | Effort | Input | Output | Thinking | Cache | Total |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|---|---|')
    $fmt = { param($v) if ($null -eq $v) { 'N/A' } else { '{0:N0}' -f [long]$v } }
    foreach ($u in $script:Usage) {
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f $u.agent, $u.round, $u.requested_model, $u.effort,
            (& $fmt $u.input), (& $fmt $u.output), (& $fmt $u.thinking), (& $fmt $u.cache_read), (& $fmt $u.total)))
    }
    $totCells = foreach ($col in 'input', 'output', 'thinking', 'cache_read', 'total') {
        $vals = @($script:Usage | ForEach-Object { $_.$col } | Where-Object { $null -ne $_ })
        if ($vals.Count -eq 0) { 'N/A' } else { '{0:N0}' -f ($vals | Measure-Object -Sum).Sum }
    }
    [void]$sb.AppendLine(('| **all** | | | | {0} | {1} | {2} | {3} | {4} |' -f @($totCells)))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('N/A = the CLI did not report it. Sums include only reported values. agy total is as reported by agy;')
    [void]$sb.AppendLine('Codex reports no total, so its total = input + output (cache is part of input, reasoning part of output).')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Total agent calls: $($script:Usage.Count)")
    [void]$sb.AppendLine("- Total review cycles: $roundsDone")
    [void]$sb.AppendLine("- Escalations: $($escalations.Count)")
    foreach ($e in $escalations) { [void]$sb.AppendLine("  - $e") }

    Write-Utf8 (Join-Path $script:RunDir 'summary.md') (Protect-Secrets $sb.ToString())
    Write-Log "summary: $(Join-Path $script:RunDir 'summary.md')"
}

$script:ExitCode = 3
try { Invoke-Pipeline | Out-Null }
catch {
    Write-Log ("unexpected error: {0} at line {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'ERROR'
    $script:ExitCode = 3
}
finally {
    if ($lock) { $lock.Close() }
    Remove-Item -LiteralPath $lockPath, $script:EmptyFile -Force -ErrorAction SilentlyContinue
    Write-Host ("AI_PIPELINE_RESULT exit={0} log={1}" -f $script:ExitCode, $script:RunDir)
}
exit $script:ExitCode
