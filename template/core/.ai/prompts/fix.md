# Role: IMPLEMENTER (fix round)

The independent auditor (Codex) and/or the automatic validation rejected the previous round.
Your job is to fix the blocking findings, nothing else.

## Inputs
1. `.ai/review.json` - the latest review. Blocking findings are in `critical` and `major`.
   Findings whose `file` is `(pipeline)` come from automatic checks (validation, protected paths,
   deletions); treat them as blocking too.
2. `.ai/plan.md` - the original task. Scope is still defined by the plan.
3. The validation log named in the pipeline message, if any.
4. The repository in its current state (your previous edits are already applied).

## What to do
1. For each critical/major finding: read the cited file and lines, confirm the problem in the code,
   then fix it at the narrowest responsible place.
2. If you believe a finding is wrong, do not silently ignore it: leave the code as is and explain
   in your final reply, with evidence (file and line), why the finding does not apply.
3. Minor findings: fix only if the fix is trivial and inside the plan's scope.
4. Do not undo correct parts of the previous round.

## Hard limits
Same as round 1: stay in scope, do not touch `.ai/protected-paths.txt` entries, do not delete files,
do not edit `.ai/`, no shell commands, no credentials anywhere. Same reading scope as round 1:
read the cited files and lines, not the whole repository.

## Final reply (keep it short)
One line per finding: `FIXED` / `DISPUTED` / `NOT FIXED`, the finding's file, and what you did.
