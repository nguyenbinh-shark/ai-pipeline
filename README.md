# ai-pipeline

Pipeline multi-agent cho Windows/PowerShell 5.1: **Claude** (lead, lập plan) → **agy** (Antigravity/Gemini, sửa code,
không có shell) → **validation** → **Codex** (review độc lập, sandbox read-only) → vòng sửa, tối đa 3 vòng.
Không bao giờ commit/push/reset/xóa file. Hướng dẫn sử dụng hằng ngày: [template/core/.ai/README.md](template/core/.ai/README.md)
(được cài vào mỗi project thành `.ai/README.md`).

## Cài vào một project

```powershell
powershell -ExecutionPolicy Bypass -File P:\prj_2026.1\ai-pipeline\install.ps1 -Target "D:\duong dan\project"
```

| Tham số | Tác dụng |
|---|---|
| `-Update` | Thay phần lõi bằng bản mới (bắt buộc khi file lõi trong project khác bản ở đây) |
| `-Preset auto\|python\|node\|dotnet\|none` | Mẫu `.ai/checks.ps1` (mặc định tự nhận) |
| `-DryRun` | Chỉ in ra sẽ làm gì |
| `-InitGit` | `git init` nếu thư mục chưa là git repo |
| `-SkipCheck` | Bỏ bước `-CheckConfig` sau khi cài |

Mọi xung đột được kiểm tra trước khi ghi; không có `-Update` thì không ghi đè file nào khác nội dung.
Exit: 0 ok · 1 xung đột (dùng `-Update`) · 2 sai tham số / không phải git repo · 3 cài xong nhưng `-CheckConfig` lỗi.

Sau khi cài: điền `AGENTS.md` (các dòng TODO), xem lại `.ai/checks.ps1`, `.ai/protected-paths.txt`,
`.ai/context-ignore.txt`. Nếu đã có commit, commit các file mới (bạn tự làm; pipeline cần tree sạch hoặc `-AllowDirty`).

## Lõi và phần riêng của project

| Loại | File | Khi `install -Update` |
|---|---|---|
| **Lõi** (`template/core`) | `scripts/ai-pipeline.ps1`, `.ai/validate.ps1`, `.ai/prompts/*`, `.ai/review.schema.json`, `.ai/.gitignore`, `.ai/README.md` | Thay bằng bản mới |
| **Khối có đánh dấu** (`template/blocks`) | Đoạn giữa `<!-- ai-pipeline:begin -->` và `<!-- ai-pipeline:end -->` trong `AGENTS.md`, `GEMINI.md`, `CLAUDE.md` | Chỉ thay đoạn đó; phần còn lại của file giữ nguyên |
| **Project** (`template/project`, `presets`) | `.ai/plan.md`, `.ai/protected-paths.txt`, `.ai/context-ignore.txt`, `.ai/checks.ps1`, `AGENTS.md` (lần đầu) | Không bao giờ ghi đè |
| Ghi tự động | `.ai/pipeline-version.txt` | Ghi khi phiên bản đổi |

File của pipeline luôn được bảo vệ sẵn trong script (`$BuiltinProtected`); `.ai/protected-paths.txt` chỉ cần
liệt kê file của project.

## Sửa pipeline

1. Sửa trong `template/`, `presets/` hoặc `install.ps1` ở repo này — **không** sửa file lõi trong từng project.
2. Tăng `$PipelineVersion` trong `template/core/scripts/ai-pipeline.ps1` nếu thay đổi đáng kể.
3. Chạy test:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1           # ~1 phút, không tốn token
   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Real     # + một lần chạy thật (~200k token)
   ```
   `-SkipCli` bỏ các test gọi agy/codex, `-Keep` giữ lại repo test trong `%TEMP%`.
4. `install.ps1 -Target <project> -Update` cho từng project đang dùng.

Test bao gồm: cài/cập nhật/xung đột/giữ file project; plan mẫu và tree bẩn bị từ chối; 7 kịch bản Mock với exit
code đúng, re-review có trọng tâm, escalation; phát hiện sửa file bảo vệ và xóa file (kịch bản `canary-*`);
validation (lỗi cú pháp, test hỏng); cấu hình model (mặc định, override, model/effort sai → dừng); tùy chọn một
lần chạy thật có kiểm tra token và secret.

## Cấu trúc

```
install.ps1
template/core/      file lõi (được copy nguyên vào project)
template/project/   file mẫu riêng của project (chỉ tạo khi chưa có)
template/blocks/    khối chèn vào AGENTS.md / GEMINI.md / CLAUDE.md
presets/<tên>/      mẫu .ai/checks.ps1: python, node, dotnet, none
tests/run-tests.ps1
```

## Yêu cầu

Windows, PowerShell 5.1, git. agy (`~\.gemini\bin\agy.exe`) và Codex (CLI trên PATH hoặc bản đi kèm extension
`openai.chatgpt-*` của VS Code) đã đăng nhập. Mọi file `.ps1` phải chỉ dùng ASCII.
