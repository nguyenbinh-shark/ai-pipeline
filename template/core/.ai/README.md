# Hướng dẫn sử dụng multi-agent pipeline

Pipeline tự động: **Claude** lập kế hoạch → **agy** (Gemini) sửa code → **validation** → **Codex** review độc lập →
lặp lại tối đa 3 vòng. Pipeline **không bao giờ commit, push, reset, xóa file** — bạn luôn tự xem diff và tự commit.

```
Bạn ──task──▶ Claude ──.ai/plan.md──▶ agy (implement) ──▶ validate.ps1 ──▶ Codex (review, read-only)
                ▲                        ▲                                      │
                │                        └──────── FAIL: vòng sửa (≤ 3) ◀───────┤
                └──────── exit 4: escalate về Claude để sửa plan ◀──────────────┘
```

---

## 1. Cách dùng hằng ngày

### Cách 1 — nhờ Claude (khuyên dùng)
Gõ trong khung chat Claude Code:

> dùng pipeline: *mô tả task*

Claude viết `.ai/plan.md`, chạy pipeline, rà diff rồi báo cáo: PASS/FAIL, file đã đổi, finding còn lại, những gì chưa
kiểm chứng. Các câu khác cũng dùng được: "chạy -CheckConfig", "chạy pipeline với effort high".

### Cách 2 — tự chạy trong terminal VS Code (`` Ctrl+` ``)
1. Viết `.ai/plan.md` (xem mục 2).
2. Chạy:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ai-pipeline.ps1 -AllowDirty
   ```
3. Mở `.ai\logs\<run>\summary.md` và `round-N\diff-cumulative.patch` của vòng cuối.

> `-AllowDirty` cần khi working tree có thay đổi chưa commit (hoặc repo chưa có commit nào).
> Thay đổi sẵn có của bạn **được giữ nguyên**; pipeline chụp baseline và chỉ tính phần agent sửa.

---

## 2. Viết plan (`.ai/plan.md`)

Plan là nguồn duy nhất về phạm vi cho agent. Pipeline từ chối chạy nếu file còn là mẫu. Các mục:

| Mục | Nội dung |
|---|---|
| Task | Một đoạn: người dùng muốn gì |
| Context | File, hàm, quy ước liên quan — **ghi đường dẫn cụ thể** |
| Implementation steps | Từng bước: file → thay đổi chính xác |
| Out of scope | Những gì agent không được đụng |
| Acceptance criteria | Câu kiểm tra được, dạng checklist |
| Validation | `validate.ps1` sẽ kiểm gì; phần nào phải kiểm tay |

Plan càng cụ thể (tên file, dòng, hàm) thì agent càng ít đọc lan man → **ít token và ít vòng sửa**.

---

## 3. Tham số

| Tham số | Tác dụng |
|---|---|
| `-AllowDirty` | Cho phép chạy khi working tree có thay đổi chưa commit |
| `-CheckConfig` | Chỉ kiểm tra CLI, đăng nhập và model rồi thoát. Không tốn token, không cần plan |
| `-Mock <kịch bản>` | Thử vòng lặp không gọi agent: `pass`, `fail-then-pass`, `always-fail`, `bad-json`, `escalate-lead`, `repeat-finding`, `escalate-implementer` (`canary-*` chỉ dùng cho test của repo ai-pipeline) |
| `-FullValidation` | Truyền `-Full` cho `.ai/checks.ps1` (phần kiểm tra chậm của project) |
| `-MaxRounds 3` | Số vòng tối đa (1–10) |
| `-AgentTimeoutMinutes 30` | Thời gian tối đa cho mỗi lần gọi agent |
| `-AgyModel`, `-AgyEffort`, `-CodexModel`, `-CodexEffort` | Ghi đè model cho lần chạy này |

---

## 4. Model

Model luôn được truyền **tường minh** và kiểm tra với danh sách thật (`agy models`, `codex debug models`) trước khi
chạy. Sai tên hoặc effort → dừng ngay (exit 2), **không tự đổi sang model khác**.

| Vai trò | Mặc định | Biến môi trường |
|---|---|---|
| agy — implement | `gemini-3.8-flash` + effort `medium` | `AI_AGY_MODEL`, `AI_AGY_EFFORT` |
| agy — khi escalate | `gemini-3.1-pro` + effort `high` | `AI_AGY_ESCALATION_MODEL`, `AI_AGY_ESCALATION_EFFORT` |
| Codex — review | `gpt-6-astra` + reasoning `medium` | `AI_CODEX_MODEL`, `AI_CODEX_EFFORT` |

- Thứ tự ưu tiên: **tham số > biến môi trường > `$DefaultConfig`** ở đầu `scripts/ai-pipeline.ps1`.
- Effort của agy: `low`, `medium`, `high`, hoặc `none` cho model không có hậu tố effort. Có thể ghi thẳng ID đầy đủ,
  ví dụ `AI_AGY_MODEL=gemini-3.8-flash-low`.
- Effort của Codex tùy model (thường `low`…`xhigh`/`max`); `-CheckConfig` sẽ báo các giá trị hợp lệ.

**Task khó — tăng effort cho lần chạy này:**
```powershell
$env:AI_AGY_EFFORT = 'high'; $env:AI_CODEX_EFFORT = 'high'
.\scripts\ai-pipeline.ps1 -CheckConfig        # xác nhận trước
.\scripts\ai-pipeline.ps1 -AllowDirty
Remove-Item Env:AI_AGY_EFFORT, Env:AI_CODEX_EFFORT
```
Biến `$env:` chỉ sống trong cửa sổ terminal hiện tại.

**Chạy `-CheckConfig` khi:** vừa cập nhật agy hoặc extension Codex, vừa đổi biến `AI_*`, hoặc pipeline báo exit 2.

---

## 5. Kết quả và exit code

| Exit | Ý nghĩa | Việc cần làm |
|---|---|---|
| 0 | PASS | Xem diff, tự commit nếu ổn |
| 1 | Vẫn FAIL sau số vòng tối đa | Đọc `.ai/review.json`; thu hẹp task hoặc sửa tay |
| 2 | Lỗi setup/cấu hình (plan còn là mẫu, repo đang bẩn khi không có `-AllowDirty`, model sai, run khác đang chạy) | Đọc thông báo; chạy `-CheckConfig` |
| 3 | Agent lỗi (timeout, chưa đăng nhập, JSON hỏng) | Xem `pipeline.log` và file stdout/stderr của agent |
| 4 | **Escalate về lead** | Đọc `escalation.md`; **sửa plan** hoặc tự quyết định, đừng chạy lại y nguyên |

### Khi nào escalate
- Codex khuyên `escalate_implementer` → các vòng sau dùng model agy mạnh hơn.
- **Dừng, exit 4** khi có một trong các điều sau:
  - finding chặn thuộc loại architecture, concurrency, data-corruption hoặc ambiguous-requirement;
  - finding security mức critical;
  - Codex khuyên `escalate_lead`;
  - **cùng một finding chặn xuất hiện ở 2 vòng liên tiếp**, để không đốt thêm vòng vô ích.

Finding `critical` và `major` chặn PASS; `minor` không bao giờ chặn.

### Các file trong `.ai\logs\<run>\`

| File | Nội dung |
|---|---|
| `summary.md` | **Đọc file này trước**: kết quả, file đã đổi, finding, model, token |
| `run.json` | Bản máy đọc được: model đã yêu cầu, escalation, usage |
| `escalation.md` | Chỉ có khi exit 4: lý do dừng |
| `pipeline.log` | Log từng bước |
| `plan.md` | Bản sao plan của lần chạy |
| `round-N\diff-cumulative.patch` | Toàn bộ thay đổi từ baseline đến vòng N |
| `round-N\diff-round.patch` | Chỉ phần sửa trong vòng N (từ vòng 2) |
| `round-N\review.json` | Review đã gộp (Codex + kiểm tra tự động) |
| `round-N\validation.txt` | Kết quả `validate.ps1` |
| `round-N\agent-report.txt` | Báo cáo của agy — chỉ là lời tự khai, Codex kiểm lại |

`.ai/review.json` luôn là review của vòng mới nhất.

---

## 6. Token đã dùng

Xem mục **AI Usage** cuối `summary.md`:

| Agent | Round | Model | Effort | Input | Output | Thinking | Cache | Total |
|---|---|---|---|---|---|---|---|---|

cùng với số lần gọi agent, số vòng review và số lần escalation.

- `N/A` = CLI không báo con số đó; pipeline không ước lượng.
- Total của Codex là **số tính ra** (input + output), vì Codex không báo tổng.
- Cột Cache không cộng thẳng được: với Codex, cache đã nằm trong input; agy báo riêng.
- `actual_model = unavailable`: không CLI nào cho biết model thực sự được server dùng. Với agy, cột
  `cli_resolved_model` lấy label từ log của chính agy; nếu label khác model đã yêu cầu thì pipeline báo lỗi.
- Đây là token của pipeline, **không phải quota còn lại** của tài khoản Gemini hay ChatGPT.

Tổng token qua mọi lần chạy:
```powershell
Get-ChildItem .ai\logs\*\run.json | ForEach-Object { (Get-Content $_ -Raw | ConvertFrom-Json).usage } |
  Group-Object agent | ForEach-Object { '{0}: {1:N0} tokens' -f $_.Name, ($_.Group | Measure-Object total -Sum).Sum }
```

---

## 7. An toàn — pipeline làm gì và không làm gì

- **Không** commit, push, reset, checkout, clean, stash, xóa file. Thứ duy nhất ghi vào `.git` là các object cho
  snapshot (vô hại; `git gc` sẽ dọn).
- agy chạy **không có quyền shell** nên không chạy được git hay lệnh xóa; chỉ đọc và sửa file.
- Codex chạy trong sandbox **read-only**.
- Sửa file trong `.ai/protected-paths.txt` hoặc xóa file → finding critical tự động.
- Secret (API key, token) bị che trong mọi log.
- Mỗi lần chỉ một pipeline chạy (khóa `.ai/logs/.lock`).
- Pipeline chỉ chạy những kiểm tra có trong `validate.ps1` và `.ai/checks.ps1`. Những gì không tự động được
  (phần cứng, phần mềm có license, thí nghiệm…) bạn vẫn phải tự chạy.

---

## 8. Lưu ý khi dùng

- **Đừng sửa file khi pipeline đang chạy**: mọi thay đổi so với baseline đều bị tính là của agent.
- Nên commit trước khi chạy để diff sạch hơn (không bắt buộc).
- agy tốn khoảng 100k+ token input ngay cả với task nhỏ; plan cụ thể giúp giảm.
- `.ai/logs/` tăng dần theo thời gian — thỉnh thoảng tự xóa các lần chạy cũ (thư mục đã nằm trong gitignore).
- File `.ps1` phải **chỉ dùng ASCII** (kể cả `.ai/checks.ps1`). Chữ tiếng Việt cần kiểm tra thì đặt trong file
  `.txt` UTF-8, ví dụ `.ai/required-anchors.txt`.
- `.ai/checks.ps1` không được ghi file vào repo (cache, coverage, build output) — nếu có, thêm vào `.gitignore`,
  nếu không chúng sẽ bị tính là thay đổi của agent ở vòng sau.

## 9. Xử lý sự cố

| Triệu chứng | Cách xử lý |
|---|---|
| `Another pipeline run holds ... .lock` | Nếu chắc không có lần chạy nào khác, xóa `.ai\logs\.lock` |
| `.ai/plan.md is still the template` | Viết plan trước |
| `Refusing to start ...` | Thêm `-AllowDirty` hoặc commit trước |
| `CONFIG_STATUS=ERROR ... not in 'agy models'` | Model đã đổi tên sau khi cập nhật; chọn lại theo danh sách được in ra |
| Exit 3, agy status ERROR | Đăng nhập lại agy (mở Antigravity), rồi `-CheckConfig` |
| Exit 3, Codex exit khác 0 | Kiểm tra đăng nhập Codex trong extension; xem `codex.stdout.jsonl` |
| Codex báo thư mục untrusted | Mở project một lần trong extension Codex, hoặc thêm vào `[projects]` trong `~\.codex\config.toml` |
| `agy had denied actions` | Agent cố làm việc không được phép (thường là chạy lệnh shell); xem `agent-report.txt` |

---

## 10. Cài vào project khác và cập nhật

Pipeline được cài từ repo `P:\prj_2026.1\ai-pipeline` (xem `.ai/pipeline-version.txt`). Project phải là git repo
(`git init` là đủ). agy và Codex đăng nhập một lần cho cả máy.

```powershell
# cài mới (preset test tự nhận: python / node / dotnet / none)
powershell -ExecutionPolicy Bypass -File P:\prj_2026.1\ai-pipeline\install.ps1 -Target "D:\du an moi"
# cập nhật phần lõi sau khi sửa repo ai-pipeline
powershell -ExecutionPolicy Bypass -File P:\prj_2026.1\ai-pipeline\install.ps1 -Target "D:\du an moi" -Update
```
Thêm `-DryRun` để xem trước, `-Preset python|node|dotnet|none` để chọn preset, `-InitGit` nếu chưa có git.

**Sau khi cài, điền phần riêng của project** (install `-Update` không bao giờ ghi đè các file này):

| File | Việc cần làm |
|---|---|
| `AGENTS.md` | Điền các dòng TODO: project là gì, cấu trúc, quy ước |
| `.ai/checks.ps1` | Test/build thật của project (preset đã có sẵn pytest/unittest, `npm test`, `dotnet test`) |
| `.ai/protected-paths.txt` | File của project agent không được sửa |
| `.ai/context-ignore.txt` | Thư mục/file agent không nên đọc (dependency, build output, dữ liệu lớn) |
| `.ai/required-anchors.txt` | Tùy chọn: dòng mở đầu phải giữ nguyên trong file nào đó |

**Đừng sửa file lõi ngay trong project** (script, prompts, schema, `validate.ps1`, README này): sửa ở repo
`ai-pipeline`, chạy test ở đó (`tests\run-tests.ps1`), rồi `install.ps1 -Update` cho từng project.

---

## 11. Các file của pipeline

| File | Vai trò |
|---|---|
| `scripts/ai-pipeline.ps1` | Orchestrator |
| `.ai/plan.md` | Task hiện tại (Claude ghi đè mỗi lần) |
| `.ai/review.json` | Review mới nhất |
| `.ai/review.schema.json` | Schema bắt buộc cho output của Codex |
| `.ai/prompts/*.md` | Prompt vai trò: implement, fix, audit |
| `.ai/validate.ps1` | Validation lõi: cú pháp `.py`/`.ps1`/`.json`, anchors, rồi gọi `.ai/checks.ps1` |
| `.ai/checks.ps1` | *Project*: test/build riêng |
| `.ai/protected-paths.txt` | *Project*: đường dẫn agent không được sửa (file của pipeline luôn được bảo vệ sẵn) |
| `.ai/context-ignore.txt` | *Project*: đường dẫn agent không đọc |
| `.ai/required-anchors.txt` | *Project, tùy chọn*: dòng phải giữ nguyên |
| `.ai/pipeline-version.txt` | Phiên bản đã cài và nguồn |
| `AGENTS.md` | Quy ước chung — agy và Codex cùng đọc (khối pipeline nằm giữa `<!-- ai-pipeline:begin/end -->`) |
| `GEMINI.md` | Quy tắc riêng cho agy |
| `CLAUDE.md` | Quy trình cho Claude (lead) |
