# Progress Log

Newest entries at the top. One entry per finished unit of work. See
`docs/INSTRUCTIONS.md` §6 — updating this file is part of finishing a task.

---

## 2026-06-05 — Tier 3 complete: go-to-definition + type info

**Done (verified against real Vim 8.0.0000 — 15/15 new checks PASS, 56/56 total
via `sh test/run.sh`):**
- `autoload/fakeide/goto.vim` — go-to-definition driving
  `clang -Xclang -ast-dump=json -Xclang -ast-dump-filter=<sym>` over the buffer
  on stdin (unsaved decls reflected, same stdin design as Tier 1/2):
  - Parses clang's **stream of top-level JSON objects** (no array wrapper). We
    split on column-0 `{` … `}` boundaries and `json_decode()` each independently.
  - `-ast-dump-filter` is a **prefix match**, so `pick_decl` enforces
    `name == sym` AND `kind =~ Decl$` AND `loc.line` is present. Implicit
    builtins matched only by prefix (`loc: {}`) are skipped.
  - Same-file matches win over cross-file; `loc.file == "<stdin>"` is remapped
    back to the buffer's absolute path. Header decls come back with the real
    file path (absolute, because we pass `-I<abs file dir>`).
  - **Vimgrep fallback** (quickfix) when the AST primary returns nothing.
  - **Own jump stack** (`s:tagstack`) — `settagstack()`/`gettagstack()` are
    8.0.1453+, NOT in 8.0.0000. Verified by tests: pop restores file + line + col.
- `autoload/fakeide/info.vim` — type/signature info:
  - Reuses Tier 2's `code-completion-at`. Aims at the **start** of the cword so
    candidates come back with empty prefix (rich result set); picks the entry
    whose `word == cword`. Same `[#ret#]`/`<#param#>` unwrapping as
    `complete.vim`. Renders one line (`<ret> <signature>`) via command-line echo,
    or `:pedit` preview when `g:fakeide_info_in_preview=1`.
  - **On-demand only** (`K` / `:FakeIdeInfo`) — never on `CursorHold`, same
    synchronous-blocking constraint as omnifunc.
- `plugin/fakeide.vim`: defaults (`fakeide_goto_timeout`, `fakeide_info_timeout`,
  `fakeide_info_in_preview`) + commands `:FakeIdeJump`, `:FakeIdeBack`,
  `:FakeIdeInfo`. `autoload/fakeide.vim` calls `fakeide#goto#enable()` and
  `fakeide#info#enable()` from `fakeide#enable()`.
- `test/fixtures/tier3/{.fakeide,lib.h,main.cpp}` — deterministic cross-file
  fixture; new `test/goto.vim` (8 checks) + `test/info.vim` (7 checks);
  `test/run.sh` loop extended with `goto info`.

**Key decisions / gotchas (also in DESIGN.md §5.5 / §5.6):**
- **Prefix-match trap in clang's `-ast-dump-filter`.** Probing with filter `x`
  matched 40 implicit `__clang_svintNNx2_t` typedefs alongside the real `x`
  field. Without our `name == sym` guard, goto on `x` would land on a builtin
  typedef. The `goto-no-prefix-jump` test pins this: probing with bare token
  `compute` (prefix of `compute_sum`) must NOT silently jump to `compute_sum`'s
  decl — it falls through to vimgrep.
- **No `settagstack` in 8.0.0000.** Settled on a script-local stack of
  `{bufnr, lnum, col, file}` rather than emulating tag-stack APIs.
- **Sync wait, same as Tier 2.** Both goto and info run `clang` via the async
  `job.vim` (tagged `goto:<bufnr>` / `info:<bufnr>`, superseding stale runs)
  then **`:sleep 10m` poll** until on_done fires (cap = timeout+500ms). One-shot
  user actions — never auto-fired — so the brief UI block is acceptable.
- **AST dump output is heavy.** Even with `-ast-dump-filter` reducing what's
  *printed*, clang still parses the full TU and prints the entire subtree of
  each match (Tier 2's "Point" filter is ~530 lines). Acceptable for an explicit
  jump; not acceptable on every keystroke (we never autorun it).

**Exact commands used:**
- Goto:
  `clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics -Xclang -ast-dump=json -Xclang -ast-dump-filter=<sym> -x c++ <flags> -I<dir> -`
- Info (same as Tier 2 completion):
  `clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics -x c++ -Xclang -code-completion-at=-:L:STARTCOL <flags> -I<dir> -`

Verified via the fixture `test/fixtures/tier3/main.cpp`:
- `<C-]>` on `compute_sum` (line 22 col 15) → `lib.h:5:5` (cross-file).
- `<C-t>` → back to `main.cpp:22:15`.
- `<C-]>` on `local_helper` (line 23) → `main.cpp:14` (same-file).
- `K` on `w.width` → echoes `int width`; on `w.area()` → `int area() const`;
  on `compute_sum` → `int compute_sum(int a, int b)`.

**How to run:** `sh test/run.sh`  ·  try it: `vim80 -Nu test/vimrc
test/fixtures/tier3/main.cpp`, position cursor on a name and press `<C-]>` /
`<C-t>` / `K` (or `:FakeIdeJump` / `:FakeIdeBack` / `:FakeIdeInfo`).

**Dev-env note:** the `~/opt/vim80` build from 2026-06-04 was no longer present
this session, so we rebuilt from the same recipe (PROGRESS.md 2026-06-04, also
in DESIGN §11). Build clean on Apple clang 17. The user's `vim80` shell alias
should point at `~/opt/vim80/bin/vim` (not yet in `~/.zsh/*.zsh` — only
`vim=nvim` is there; worth pinning it so future agents don't re-discover this).

**Daily-use install (this session, after Tier 3):**
- Added `after/ftplugin/c.vim` and `after/ftplugin/cpp.vim` (one-liners,
  `setlocal omnifunc=fakeide#complete#omni`). Reason: Vim's bundled
  `$VIMRUNTIME/ftplugin/cpp.vim` runs after ours and resets `omnifunc` to
  `ccomplete#Complete` — fake-ide's omnifunc otherwise loses to the built-in
  the moment you `vim80 foo.cpp` without `-Nu test/vimrc`.
- Created `~/.vimrc` (read by `vim80` only — nvim reads its own
  `~/.config/nvim/init.lua`) that adds BOTH the project root AND `<root>/after`
  to runtimepath (standard pathogen-style convention). Updated `test/vimrc` to
  do the same so the layout stays consistent.
- Created `~/.zsh/vim80.zsh` with `alias vim80="$HOME/opt/vim80/bin/vim"`
  (sourced automatically by `~/.zshrc`).
- DESIGN §4 directory layout now lists `after/ftplugin/` and notes the
  `runtimepath+=...after` requirement. TESTING.md gained a "Daily-use install"
  block at the top.
- **Heads-up:** the pinned Vim 8.0 build at `~/opt/vim80/` was not present at
  the start of this session — rebuilt from the 2026-06-04 recipe (worked
  unchanged on Apple clang 17). Tier 0's PROGRESS entry is still the
  reproducible source for the build steps.

**Verified wakeup (vim80 outside the project):** `vim80 /tmp/any.cpp` →
`filetype=cpp`, `b:fakeide_active=1`, `omnifunc=fakeide#complete#omni`,
`<C-]>`/`K` mapped. Plus the headless suite remains 56/56 PASS after the
after/ftplugin + runtimepath changes.

**Next:** Polish / PCH. Highest-leverage remaining items (DESIGN §7):
- **PCH for system headers** — biggest completion / goto / info speedup; still
  the open item from Tier 2 (also helps Tier 3 since the same TU is parsed).
- Save-only diagnostics mode + per-project flag overrides for very heavy files.
- Async `complete()` auto-trigger path (would also let info auto-fire on
  CursorHold without blocking).
- Open question #5 (install location: per-user `~/.vim/` vs. checked-in
  project-local `runtimepath`) still untouched.

---

## 2026-06-05 — Tier 2 complete: semantic completion (omnifunc → clang)

**Done (verified against real Vim 8.0.0000 — 16/16 new checks PASS, 40/40 total
via `sh test/run.sh`; plus a real `i_CTRL-X_CTRL-O` round-trip observed):**
- `autoload/fakeide/complete.vim` — `omnifunc=fakeide#complete#omni` driving
  `clang -Xclang -code-completion-at=-:L:C -` over the buffer on **stdin** (unsaved
  edits reflected, same design as Tier 1 diagnostics):
  - **Two-call contract.** `findstart` scans back over `\k` chars for the partial
    word **and snapshots `[line, col]`**; the candidates call reuses that snapshot
    (Vim can move the cursor between the two calls — caught this and fixed it).
  - Points clang at the **cursor** (end of the partial) so **clang filters by the
    typed prefix** — critical to avoid dumping 1000s of entries for `std::`.
  - **Parses `COMPLETION:` lines** (stdout): splits name/sig on the first ` : `,
    skips `(Inaccessible)`/`(Hidden)`, extracts return type `[#…#]`, unwraps
    `<#param#>` / `{#opt#}` / trailing `[# const#]`. Emits Vim dicts with
    `word`/`menu`(rettype)/`info`(signature)/`kind` (`f`/`v`/`t`/`d`); dedups by
    word+menu (keeps distinct overloads); caps at `g:fakeide_complete_max` (200).
  - Wired via `fakeide#complete#enable()` ← `fakeide#enable()`. Opt-in auto-trigger
    maps for `.`/`->`/`::` (`g:fakeide_complete_auto`, default **off**).
- `plugin/fakeide.vim`: config defaults (`fakeide_complete_auto`/`_timeout`/`_max`)
  + `:FakeIdeComplete`.
- `test/fixtures/tier2/{.fakeide,sample.cpp}`, `test/complete.vim`; `test/run.sh`
  now runs `smoke`, `diag`, **`complete`**.

**Key decision / gotcha — synchronous omnifunc (documented tradeoff):**
- Vim 8.0's omnifunc/completefunc contract is **synchronous**: the function must
  *return* the list. 8.0 has **no non-blocking completion API** short of the
  `complete()` re-trigger hack (flickers). So the omnifunc runs clang through the
  async `job.vim` (superseding stale jobs by tag `complete:<bufnr>`) but then
  **waits on a bounded `sleep 10m` poll loop** until `on_done` fires (cap =
  `g:fakeide_complete_timeout`+500ms). `:sleep` is a point where Vim pumps
  channel callbacks — verified this works for a real `i_CTRL-X_CTRL-O`, not just
  direct calls. Net: completion briefly **blocks the UI** for the parse, but only
  on an explicit request, never per-keystroke. This is the documented "no daemon"
  cost (DESIGN §5.4/§10); auto-trigger is opt-in for that reason. **This bends the
  "never block the UI" rule** — flagging it: it is unavoidable for a synchronous
  omnifunc in 8.0. Async `complete()` auto-trigger is noted as future work.
- **Test/pty gotcha:** ad-hoc `script …` one-offs are flaky here AND need
  `TERM=xterm` or Vim won't start under the pty. `sh test/run.sh` (which sets it)
  is the reliable harness. Also: a `call cursor()` *outside* the feedkeys stream
  doesn't stick for completion — drive navigation *inside* feedkeys
  (`10G0f.a\<C-x>\<C-o>`) to verify the real path.

**Exact command used (completion):**
`clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics -x c++ -Xclang -code-completion-at=-:L:C <flags> -I<dir> -`
(buffer on stdin). Verified at `p.` in `test/fixtures/tier2/sample.cpp`: returns
`dist/move/operator=/Point/x/y/~Point` with return types + signatures; partial
`p.di` filters to `dist`; an unsaved struct member appears in the menu.

**How to run:** `sh test/run.sh`  ·  try it:
`~/opt/vim80/bin/vim -Nu test/vimrc test/fixtures/tier2/sample.cpp`, go to the
`p.x` line, `i` after the `.`, press `CTRL-X CTRL-O` (or `:FakeIdeComplete`).

**Next:** Tier 3 — `goto.vim` (go-to-definition via clang AST dump / vimgrep
fallback) and `info.vim` (type/signature echo + preview window). PCH support for
system headers is the highest-leverage completion speedup and still open.

---

## 2026-06-05 — Tier 1 complete: live diagnostics (signs + loclist + echo)

**Done (verified against real Vim 8.0.0000, 22/22 checks PASS via `sh test/run.sh`):**
- `autoload/fakeide/diag.vim` — async `clang -fsyntax-only` diagnostics engine:
  - Buffer fed on **stdin** (`-x <c|c++> … -`) so unsaved edits are reflected;
    `<stdin>` is remapped back to the buffer. `-I<file dir>` preserves quoted
    `#include` resolution; `-fno-caret-diagnostics` keeps output to one line each.
  - **Manual `matchlist()` parsing** of `file:line:col: severity: message`.
    `getqflist({'lines':…})` is NOT used — that dict form is absent in 8.0.0000
    (verified: returns no items).
  - **Gutter signs** via `:sign place`/`:sign unplace` (8.0.0000 has no
    `sign_place()` and no sign groups); placed ids tracked in `b:fakeide_sign_ids`
    and unplaced on refresh. One sign per line, error beats warning.
  - **Location list** per window; header errors keep their real path.
  - **Cursor echo** of the diagnostic under the cursor (our 8.0 "hover").
  - Triggers: `BufWritePost` always + debounced `CursorHold` (default on) /
    `TextChangedI` (default off). `]d`/`[d` → `:lnext`/`:lprev`.
- Wired `fakeide#diag#enable()` into `fakeide#enable()`; added `:FakeIdeCheck`,
  `:FakeIdeClear` to `plugin/fakeide.vim`.
- `test/fixtures/tier1/{.fakeide,broken.c}` (deterministic `#warning` + an
  undeclared-identifier error); new `test/diag.vim`; `test/run.sh` now runs both
  `smoke.vim` and `diag.vim`.

**Key decisions / gotchas (also in DESIGN.md §5.2–5.3):**
- **Job-wrapper bug found & fixed (Tier 0 regression):** with separate
  stdout/stderr pipes, a process that writes ONLY to stderr (empty stdout) loses
  its stderr — stdout EOFs instantly, `close_cb` finalizes before the buffered
  stderr is delivered. `clang -fsyntax-only` is exactly this (all output on
  stderr), so Tier 1 initially saw zero diagnostics. Fix: `job.vim` now merges
  stderr into stdout by default (`err_io:'out'`, opt `merge_stderr`, default 1).
  Everything arrives in `result.out`; `result.err` stays empty unless opted out.
  The old smoke tests missed this because they only exercised stdout.
- clang suppresses end-of-scope warnings (e.g. unused-variable) once a function
  has a sema error, so the fixture uses `#warning` (fires in preprocessing) for a
  deterministic warning alongside the error.
- Manual `script`/pty one-offs are flaky in this sandbox (intermittent pty
  alloc); `sh test/run.sh` is the reliable harness.

**Exact command used (diagnostics):**
`clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics -x c <flags> -I<dir> -`
(buffer on stdin). Verified: warning@line 6, error@line 8 of `broken.c`; an
unsaved appended line was also flagged, confirming the stdin/live-edit path.

**How to run:** `sh test/run.sh`  ·  try it: `~/opt/vim80/bin/vim -Nu test/vimrc test/fixtures/tier1/broken.c` then `:FakeIdeCheck`, `:lopen`, move cursor onto line 6/8.

**Next:** Tier 2 — `autoload/fakeide/complete.vim`: `omnifunc` driving
`clang -Xclang -code-completion-at=-:L:C -` over the buffer on stdin, parse
`COMPLETION:` lines into the insert-mode popup. (Completion reads stdout, so it
can use `merge_stderr=0` to keep diagnostic noise out — though the `COMPLETION:`
prefix filter also handles it.)

---

## 2026-06-04 — Tier 0 complete: async job wrapper + flag resolution + bootstrap

**Done (all verified against real Vim 8.0, 10/10 smoke checks PASS):**
- `autoload/fakeide/job.vim` — async wrapper over `job_start`. Supersede-by-tag
  (kills stale jobs), optional stdin, timeout guard, structured `on_done`
  result `{code, out, err, tag}`.
- `autoload/fakeide/flags.vim` — compile-flag resolution:
  `compile_commands.json` → `.fakeide` → defaults, with per-file caching and
  `-I`/`-isystem` paths made absolute against the entry's directory.
- `autoload/fakeide.vim` — `fakeide#enable()` per-buffer entry point.
- `plugin/fakeide.vim` — config defaults, diagnostic sign definitions,
  commands `:FakeIdeStatus`, `:FakeIdeFlags`, `:FakeIdeReloadFlags`.
- `ftplugin/c.vim`, `ftplugin/cpp.vim` — wire buffers to `fakeide#enable()`.
- `test/` — headless smoke test (`smoke.vim`), runner (`run.sh`), fixtures.

**Key decisions / gotchas (also in DESIGN.md §5.2):**
- Finish runs on **`close_cb`**, not `exit_cb` — `exit_cb` timing is unreliable
  on this build (process dead but callback never fired within 3s). Exit code
  comes from `exit_cb` if it fired, else `job_info().exitval` (briefly polled).
- List-form stdin must be newline-terminated or the last line is dropped (`nl`
  mode). Fixed + regression-tested.
- **Testing requires a pty:** `vim -es` does NOT pump job callbacks. Use
  `sh test/run.sh` (wraps Vim in `script -q /dev/null`).

**How to run:** `sh test/run.sh`   ·   try it: `~/opt/vim80/bin/vim -Nu test/vimrc test/fixtures/hello.c` then `:FakeIdeStatus`

**Next:** Tier 1 — `autoload/fakeide/diag.vim`: async `clang -fsyntax-only` on
`BufWritePost` (+ debounced idle), parse into the location list + gutter signs,
echo the message under the cursor on `CursorHold`.

---

## 2026-06-04 — Dev environment: Vim 8.0 built & installed

**Done:**
- Verified existing toolchain on the Mac: Apple clang 21 (`/usr/bin/clang`),
  Homebrew, Xcode CLT all present. System `vim` was 9.1 — too new.
- Built **Vim 8.0** from source, installed side-by-side (system vim untouched).

**Commands run (reproducible):**
```bash
git clone --depth 1 --branch v8.0.0000 https://github.com/vim/vim.git ~/src/vim
cd ~/src/vim/src
export CFLAGS="-Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-error"
./configure --prefix=$HOME/opt/vim80 --with-features=huge --enable-multibyte --with-tlib=ncurses
make -j8 && make install
```

**Key decision / gotcha:** the 2016 source fails to build on clang 21 because
implicit function declarations are now hard errors (broke configure's terminal
lib detection). Fixed with the `-Wno-...` `CFLAGS` above + forcing
`--with-tlib=ncurses`. Standard old-C-on-new-clang fix.

**Result:** `~/opt/vim80/bin/vim` reports `VIM - Vi IMproved 8.0`. Confirmed
required features present: `+job +channel +timers +signs +quickfix`.
Suggested alias: `alias vim80=~/opt/vim80/bin/vim`.

**Next:** Tier 0 — scaffold `autoload/fakeide/job.vim` (async wrapper) +
`flags.vim` (compile-flag resolution) + IDE defaults in `plugin/`.

---

## 2026-06-04 — Project docs & agent instructions set up

**Done:**
- Wrote `docs/DESIGN.md` — full architecture, tiers, estimates, risks.
- Established single-source-of-truth instructions in `docs/INSTRUCTIONS.md`;
  root `AGENTS.md` (Codex) and `CLAUDE.md` (Claude Code) are minimal pointers.
- Locked in the core constraints: Vim 8.0 only, no third party, compiler-driven
  intelligence via clang.

**Next:** stand up the dev environment (Vim 8.0).
