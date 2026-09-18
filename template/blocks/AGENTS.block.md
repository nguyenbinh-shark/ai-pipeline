## Multi-agent pipeline
`scripts/ai-pipeline.ps1` runs implementer (agy) -> validation (`.ai/validate.ps1` + `.ai/checks.ps1`) ->
auditor (Codex). State lives in `.ai/`: `plan.md` (task), `review.json` (latest review), `logs/` (per run).
The pipeline's own files and the patterns in `.ai/protected-paths.txt` must not be changed by an implementer.
