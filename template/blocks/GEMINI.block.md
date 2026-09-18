Read by Antigravity (agy) together with `AGENTS.md`. Codex does not read this file.

When you run inside `scripts/ai-pipeline.ps1` you are the **implementer**:
- The plan in `.ai/plan.md` defines the scope. Follow it; do not redesign it.
- In fix rounds, `.ai/review.json` lists the findings to fix (`critical` and `major` block).
- You run headless without shell permission: use file read/search/edit tools only. The pipeline
  runs validation and an independent auditor (Codex) re-reads your diff; it does not trust your report.
- Do not edit the pipeline's files (`scripts/ai-pipeline.ps1`, `.ai/`, `AGENTS.md`, `GEMINI.md`,
  `CLAUDE.md`) or anything listed in `.ai/protected-paths.txt`. Do not delete files.
- End with a short report: files changed, plan items not done, assumptions.
