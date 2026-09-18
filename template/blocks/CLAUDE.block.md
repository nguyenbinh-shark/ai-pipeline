## Quy trình multi-agent (Claude = lead)

Hướng dẫn đầy đủ cho người dùng: [.ai/README.md](.ai/README.md). Pipeline được cài từ repo `ai-pipeline`
(phiên bản ghi trong `.ai/pipeline-version.txt`); đừng sửa file lõi ở đây mà sửa ở repo đó rồi `install.ps1 -Update`.

Khi người dùng giao một task **code** và muốn chạy qua pipeline (hoặc nói "dùng pipeline"):

1. Claude phân tích yêu cầu, đọc repo, rồi **ghi đè `.ai/plan.md`** (Task, Context, Implementation steps,
   Out of scope, Acceptance criteria, Validation). Plan càng chỉ rõ file/dòng càng tốn ít token. Claude **không
   tự sửa code** trong quy trình này, trừ khi người dùng yêu cầu rõ.
2. Nếu task cần sửa file được bảo vệ (file của pipeline, hoặc `.ai/protected-paths.txt`), hỏi người dùng trước.
3. Chạy nền: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ai-pipeline.ps1 -AllowDirty`
   (`-AllowDirty` khi working tree có thay đổi chưa commit; thay đổi đó được giữ nguyên).
4. Đọc `.ai/logs/<run>/summary.md`, `.ai/review.json`, tự rà `round-N/diff-cumulative.patch`, rồi báo cáo ngắn:
   PASS/FAIL, số vòng, file đã đổi, finding còn lại, token (mục *AI Usage*), những gì **chưa** kiểm chứng.
5. Không commit, push, reset, checkout, clean. Exit code: 0 PASS · 1 FAIL sau số vòng tối đa · 2 lỗi setup/cấu
   hình model · 3 lỗi agent · **4 escalate về Claude** — đọc `escalation.md`, sửa plan (hoặc hỏi người dùng)
   trước khi chạy lại; đừng chạy lại y nguyên.

Model mặc định (`$DefaultConfig` trong script): agy `gemini-3.8-flash` + `medium`, escalate lên `gemini-3.1-pro` +
`high`; Codex `gpt-6-astra` + reasoning `medium`. Override: `AI_AGY_MODEL`, `AI_AGY_EFFORT`,
`AI_AGY_ESCALATION_MODEL`, `AI_AGY_ESCALATION_EFFORT`, `AI_CODEX_MODEL`, `AI_CODEX_EFFORT`, hoặc tham số
`-AgyModel -AgyEffort -CodexModel -CodexEffort`. Kiểm tra cấu hình không tốn token: `-CheckConfig`.
Kiểm tra vòng lặp không tốn token: `-Mock fail-then-pass`.

Cấu hình riêng của project (install `-Update` không ghi đè): `.ai/protected-paths.txt`, `.ai/context-ignore.txt`
(đường dẫn agent không đọc), `.ai/checks.ps1` (test/build của project, thêm `-FullValidation` cho phần chậm).
