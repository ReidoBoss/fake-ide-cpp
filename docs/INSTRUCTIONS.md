# Agent Instructions — fake-ide (C/C++ IntelliSense for Vim 8.0)

> **SHARED INSTRUCTIONS — SINGLE SOURCE OF TRUTH.**
> This file is the one set of rules every AI coding agent on this project —
> currently **Claude Code** and **Codex** — MUST follow.
>
> - The root `AGENTS.md` (Codex) and `CLAUDE.md` (Claude Code) are minimal
>   pointers to this file. All real instructions live here in `docs/`.
> - Change rules **here only**. Do not put rules in the root pointer files.
> - The authoritative design is **`docs/DESIGN.md`** — read it before making
>   changes and keep it in sync.

---

## 1. What this project is

`fake-ide` is a "fake Neovim" experience for **C and C++** that runs inside
**Vim 8.0**. It provides diagnostics, semantic completion, go-to-definition, and
type info — implemented **entirely in Vimscript** by driving the system
compilers (`clang`/`gcc`) as ordinary command-line processes.

See **`docs/DESIGN.md`** for the full architecture, build plan, and rationale.

## 2. NON-NEGOTIABLE constraints (violating any of these is a defect)

1. **Vim 8.0 ONLY.** No feature introduced after 8.0. Specifically **FORBIDDEN**:
   - `popup_*` (8.1.1+), text properties / `prop_*` (8.1+), virtual text.
   - Anything that requires Vim 8.1, 8.2, 9.x, or Neovim.
   - If unsure whether a function exists in 8.0, do not use it without checking.
   - Allowed 8.0 features: async jobs (`job_start`, `ch_*`), `timer_start`,
     signs, quickfix/location lists, `json_decode`, insert-mode completion
     (`omnifunc`/`completefunc`), `autoload/`.
2. **NO third party. At all.** This is a hard company policy.
   - **FORBIDDEN:** any Vim plugin, plugin manager, `pack/` bundle, downloaded
     script, LSP server (clangd/ccls), `ctags`/Universal Ctags, `libclang`
     linking, or any external library/tool that is not already on the machine.
   - **ALLOWED:** Vim 8.0 itself, the company's existing `clang`/`gcc` binaries
     (invoked as CLI processes), and Vimscript we write in-house.
   - The compiler is allowed **only as an invoked binary** — never link or vendor
     anything.
3. **All "intelligence" comes from invoking the compiler**, never from a
   hand-written C/C++ parser. Use:
   - `clang ... -Xclang -code-completion-at=-:LINE:COL -` for completion.
   - `clang`/`gcc -fsyntax-only` for diagnostics.
4. **Completion requires clang** (`gcc` has no `-code-completion-at`). Diagnostics
   may use either; default to clang.
5. **No background daemon/server.** Spawn short-lived compiler processes only.

## 3. Code conventions

- Language: **Vimscript** (legacy, not Vim9 script — that's 9.0+).
- Layout (see `docs/DESIGN.md` §4): user-facing commands/signs/defaults in
  `plugin/`, lazy-loaded logic in `autoload/fakeide/`, buffer wiring in
  `ftplugin/`.
- Namespacing: all functions under `fakeide#<module>#<Name>`; all internal
  state in script-local `s:` variables; user commands prefixed `FakeIde`.
- Async: route every external process through `autoload/fakeide/job.vim`. Never
  call `job_start` directly from other modules. Always kill superseded jobs.
- Never block the UI. Long work goes async with debounce (`timer_start`).
- Compile flags come from `autoload/fakeide/flags.vim` only
  (`compile_commands.json` → `.fakeide` → defaults). Never hardcode `-I` paths.

## 4. Build order (do not skip ahead without reason)

Tier 0 (job + flags + defaults) → Tier 1 (diagnostics) → Tier 2 (completion) →
Tier 3 (goto/info). Each tier must be independently working before the next.
See `docs/DESIGN.md` §7.

## 5. Testing & verification

- There is no Vim plugin test framework available (it'd be third party). Verify
  by running real Vim 8.0 against the sample C/C++ files in `test/fixtures/`
  (create them as needed).
- Before claiming something works: confirm the Vim version is actually 8.0
  (`vim --version | head -1`), then exercise the feature in a real buffer and
  report the observed behavior. Do not claim success you haven't observed.
- When a compiler invocation is involved, paste the exact command line used so
  the other agent (and humans) can reproduce it.

### Automated checks

- `sh test/run.sh` runs every headless check under a real **pty** (it wraps Vim
  in `script -q /dev/null …`). Job/channel callbacks are NOT pumped by plain
  `vim -es`, so the pty is mandatory for anything async. The runner aggregates
  `test/smoke.vim` (Tier 0: job wrapper + flags) and `test/diag.vim` (Tier 1:
  diagnostics) and exits non-zero on any `FAIL`. Add a new `test/<name>.vim` and
  a `<name>` entry to the runner's loop for each new tier.
- Heads-up: ad-hoc `script …` one-off invocations are flaky in some sandboxes
  (intermittent pty allocation). `sh test/run.sh` is the reliable path; prefer it.
- Before relying on any Vim function/feature, **probe the actual 8.0 binary**
  (`exists('*fn')`, a tiny `try/catch` smoke). The pinned build is `8.0.0000`;
  several later 8.0.x patches (e.g. `getqflist({'lines':…})`, `sign_place()`)
  are absent. Do not assume "8.0" means the latest 8.0.x.

### Manual verification (Tier 1 diagnostics)

Run real Vim 8.0 and observe — do not claim success you haven't seen:

1. `~/opt/vim80/bin/vim -Nu test/vimrc test/fixtures/tier1/broken.c`
2. Confirm the banner / `:version` says **8.0**.
3. Diagnostics auto-run on open (the ftplugin calls `fakeide#enable()`). Expect:
   - a `W>` sign on the `#warning` line (6) and an `E>` sign on the
     `return undeclared_sym;` line (8);
   - `:lopen` lists both (1 warning + 1 error); `]d` / `[d` jump between them.
4. Move the cursor onto line 8 — the error message echoes on the command line
   (our 8.0 "hover" substitute).
5. **Live/unsaved path:** in insert mode add a line such as `int x = nope;`,
   leave insert, run `:FakeIdeCheck`. A new error sign + loclist entry appears
   **without saving the file** — this proves the buffer is fed to clang on stdin.
6. `:FakeIdeClear` removes the signs + location list. `:FakeIdeStatus` prints the
   resolved flags; `:FakeIdeFlags` should include `-Wall` (from the fixture's
   `.fakeide`). `:FakeIdeReloadFlags` clears the flag cache.

Exact diagnostics command (also echoed in `docs/DESIGN.md` §5.3):
`clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics -x c <flags> -I<file dir> -`
with the buffer piped on stdin.

## 6. Working agreement between agents

- **One source of truth.** All rules live in this file (`docs/INSTRUCTIONS.md`);
  docs live in `docs/`. The root `AGENTS.md`/`CLAUDE.md` only point here.
- **Never commit automatically — stop and ask the human to commit.** After you
  implement a unit of work (code + verification + doc updates per this section),
  do NOT run `git commit` on your own. Present what changed and explicitly ask
  the human to commit, because the human verifies every change before it is
  committed. Only run `git commit` when the human explicitly tells you to in
  that turn. This keeps each commit a reviewed, verified checkpoint.
- **Update the docs every time you finish a task — not optional.** Before you
  consider a unit of work done, update `docs/` so the next agent (Claude or
  Codex) inherits an accurate picture. Specifically:
  - Append a dated entry to **`docs/PROGRESS.md`** (create it if missing): what
    you did, key decisions, exact commands run, and what's next.
  - If the architecture, file layout, or build steps changed, update
    **`docs/DESIGN.md`** to match — never let it drift from the code.
  - If a project rule or constraint changed, update this file.
  A task is not "finished" until the relevant docs reflect reality.
- **Leave a trail.** Also note what changed and why in your turn summary so the
  other agent can pick up without re-discovering context.
- **Respect the constraints above even when it's harder.** If the easy solution
  needs a plugin, a newer Vim, or a third-party tool, it is wrong here — find the
  in-house/compiler-driven way or flag it as blocked.
- If you believe a constraint must be broken, **stop and ask the human**; do not
  work around it silently.
- Prefer small, reviewable changes. Keep `docs/` truthful.
