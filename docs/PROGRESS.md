# Progress Log

Newest entries at the top. One entry per finished unit of work. See
`docs/INSTRUCTIONS.md` §6 — updating this file is part of finishing a task.

---

## 2026-06-05 — Syntax-shaped def-grep (smart-jump precision)

**Why:** user pointed out that grepping `\<sym\>` and then scoring lines
after the fact is doing the same work twice. Better to put the C/C++
definition syntax into the grep regex itself — grep filters out use sites,
calls, comments, and declarations at the source.

**Done (8/8 gcc_only checks still PASS; tier1 fixture failures unchanged):**
- `fakeide#grep_def(sym, from_file)` runs grep with a POSIX ERE shaped
  after definition syntax:
  - **type def** : `(struct|class|enum|union)[[:space:]]+SYM[[:space:]]*([:{]|$)` —
    rejects `struct Foo;` forward decls.
  - **func def** : `(^|[^[:alnum:]_])SYM[[:space:]]*\([^;{}]*\)[[:space:]]*((const|noexcept|override|final)[[:space:]]+)*(\{|$)` —
    rejects `SYM(args);` declarations (no `{` / EOL after the closing paren).
- `goto.vim`'s smart-jump tries `grep_def` FIRST. If hits, runs through
  `s:pick_definition` (which now mostly just strips `// ...` comments and
  applies the source-extension tiebreak — the regex already did the heavy
  lifting) and jumps. Only if `grep_def` returns nothing does it fall back
  to the broad word grep into the quickfix list.

**Implementation note — switched from `:grep!` to `system()` + `setqflist()`:**
- `:grep!` mangles complex ERE patterns through Vim's shell-escape path
  (specifically the `|` alternation inside single quotes — verified the
  exact same shell command works via `system()` but returns 0 items via
  `:grep!`).
- Switching to `system()` gives us full control over the invocation. We
  parse the `<file>:<lnum>:<text>` output ourselves and populate the qflist
  via `setqflist()`. Same speed; no Vim escaping interference.
- Both the broad and def-shape grep paths now go through the same
  `s:run_grep_system()` helper.

**Benchmark on a 200-file / 10k-LOC synthetic project, looking for a func
definition:**
| Path | Time |
|---|---|
| broad word grep (old) | 46ms |
| def-shape grep (new) | 32ms |

Def-shape is *faster* because the more specific regex returns fewer
matches for grep to stream out — less work even though the regex itself
is more complex.

**Accuracy win:** on real code, `gd` on `compute_sum` now jumps directly to
the *definition* line if one exists in the project, with no risk of
landing on a declaration in a header or a call site. The qf fallback only
opens for symbols that have no definition in scope.

---

## 2026-06-05 — External grep backend (refs + goto fallback)

**Why:** user reported `:vimgrep` lag on a large corp codebase. `:vimgrep`
opens each candidate file in Vim's buffer parser to scan it, which scales
poorly with file count. External `grep` is a fork/exec that streams bytes —
much faster on big trees. Measured on a synthetic 200-file project: external
~55ms vs :vimgrep ~120ms (2.2× faster); the gap widens with project size
(fork/exec overhead is constant, :vimgrep per-file parser cost is linear).

**Done (verified — all existing checks still PASS; nothing new breaks):**
- `fakeide#grep(sym, from_file)` in `autoload/fakeide.vim` dispatches:
  - external path (default, `g:fakeide_use_external_grep=1`): shells out to
    `grep -nwIE` via `:grep!`; samedir builds an explicit file list from
    `glob()`, root uses `grep -r --include=*.<ext>` from a project marker.
  - vimgrep fallback: same logic as before, called when external grep is
    disabled or `grep` isn't on `$PATH`.
- `autoload/fakeide/goto.vim` and `autoload/fakeide/refs.vim` collapsed to
  `fakeide#grep(sym, from_file)` — no more inline `:vimgrep` invocations,
  no more divergence risk between the two callers.
- README's "Tuning the project grep" section documents all three knobs
  (`use_external_grep`, `grep_scope`, `goto_grep_exts`) and shows the
  benchmark.

**Edge cases handled:**
- `grep` not on `$PATH` → silent fall-through to `:vimgrep`.
- samedir glob expands to empty → set qflist to [] explicitly (so callers'
  empty-check logic still works) and return 0.
- BSD vs GNU grep: `-nwIE` is supported by both. Word-boundary semantics
  (`-w`) are identical. `--include=` is GNU-only — we don't pass it in
  samedir mode (file list is explicit); in root mode we rely on GNU/BSD's
  shared `--include=` support (BSD grep on macOS 10.15+ has it).

**Honest limits:**
- Multi-match-per-line: external `grep -nw` reports each MATCHING LINE once,
  vimgrep with `/g` reports each MATCH separately. If a line contains
  `Point{0,0}, Point{1,1}`, vimgrep gives 2 qf entries, grep gives 1. In
  practice this rarely matters because the lines are still in the qf and the
  user picks one. Documented but not "fixed" — would require per-line
  re-grepping which defeats the speed win.

---

## 2026-06-05 — Configurable grep scope + extension filter

**Why:** user's company convention is a flat layout where all `.c` / `.h` /
`.cpp` files for a given component live in one directory. The previous
recursive-from-project-root grep pulled in unrelated files. Two new options
let users opt into a tighter search.

**Done (verified — 2 new checks PASS in `test/gcc_only.vim`, 8/8 total):**
- `fakeide#grep_globs(from_file)` and `fakeide#project_root(from_file)` moved
  into `autoload/fakeide.vim` so goto and refs can't drift apart on what they
  search. Honors:
  - `g:fakeide_grep_scope` — `'root'` (default, walk up + recurse) or
    `'samedir'` (current dir only, no recursion).
  - `g:fakeide_goto_grep_exts` — list of bare extensions, default the full
    C/C++ set.
- `autoload/fakeide/goto.vim` and `autoload/fakeide/refs.vim` now call the
  shared helper; both had inline copies of `s:project_root` and the
  extension/glob assembly that have been removed.
- README has a new "Tuning the project grep" section.

**Defaults unchanged.** Project-wide behaviour is identical for anyone who
doesn't set the two knobs. Only opt-in users (e.g. the company-convention
flat-dir layout) see the restriction.

---

## 2026-06-05 — Smart-jump heuristic in the vimgrep fallback

**Why:** user is on a gcc-only work machine and wanted goto to actually
*jump*, not just open a quickfix of textual hits. The previous behaviour
("open qf, you pick") was correct but unsatisfying — for the common case
of a single obvious function/type definition, we can do better.

**Done (verified — 1 new check PASS in `test/gcc_only.vim`, 6/6 overall):**
- `autoload/fakeide/goto.vim`:
  - `s:pick_definition(sym, qf)` scores each vimgrep hit's line text:
    - **type def** if `(struct|class|enum|union) NAME` followed by
      `{` / `:` / EOL — strongest signal.
    - **func def** if `NAME(args) { ... }` or `NAME(args)\n{` — accepts
      `const` / `noexcept` / `override` / `final` / trailing-return-type
      modifiers. Rejects `NAME(args);` (declaration only).
    - everything else (uses, calls, comments) → no candidate.
  - `s:prefer_source(hits)` picks `.cpp`/`.cc`/`.cxx` over `.h` within a tie.
  - If a unique best candidate exists, auto-jump (same UX as the AST path).
    Else fall back to `:copen` as before.
- Same heuristic applies whether we hit the fallback via no-clang or via
  the AST primary returning nothing (e.g. symbols outside the TU). Both
  paths now feel like real goto when a definition exists.

**New test check (`gcc-goto-smart-jumps`):** under `g:fakeide_has_clang=0`,
cursor on `local_helper` in tier3/main.cpp → smart-jump lands on line 14
(the `int local_helper(int x) {` definition), no qf opened. The existing
`gcc-goto-vimgrep-fallback` check confirms the qf fallback still kicks in
when no definition-shaped line exists (e.g. `compute_sum` has only a
declaration in lib.h).

**Honest limits:**
- Function-style macros that match `NAME(args) {` shape will be picked as
  definitions. Acceptable false positive — rare in practice.
- Multi-line function definitions where the brace is on the line *after*
  any modifier are still caught via the `$` (end-of-line) branch of the
  regex.
- `s:pick_definition` only looks at line content from the quickfix item's
  `text` field; it can't see surrounding context.

**Heads-up unchanged:** `test/fixtures/tier1/broken.c` is still
locally-cleaned per user direction, so `sh test/run.sh` still reports
`RESULT: FAIL` overall. All new and existing non-tier1 checks PASS.

---

## 2026-06-05 — gcc-only graceful degradation

**Why:** user's work machine has gcc but not clang. Completion / type info
need `-Xclang -code-completion-at` (clang-only), and goto's AST primary needs
`-Xclang -ast-dump=json` (also clang-only). Without this work the user gets
silent failures and confusing behaviour when those features fire against
gcc.

**Done (verified — 5/5 new checks PASS in `test/gcc_only.vim`):**
- `autoload/fakeide.vim` gains `fakeide#has_clang()`: caches the result of
  probing `<compiler> --version` for the literal "clang" (Apple's `gcc` is
  clang under the hood; GNU's isn't). Overridable via `g:fakeide_has_clang`
  for tests and for users who want to force the degraded path.
- `autoload/fakeide/complete.vim`: `s:findstart()` returns `-2` (silent
  cancel) when `!fakeide#has_clang()`, with a one-shot warning so the user
  knows why `<C-x><C-o>` is doing nothing.
- `autoload/fakeide/goto.vim`: routes directly to the existing
  `s:vimgrep_fallback()` when there's no clang (quickfix of textual hits —
  approximate but useful), one-shot warning.
- `autoload/fakeide/info.vim`: bails with a warning and prints nothing.
- `plugin/fakeide.vim`: `:FakeIdeStatus` now appends `(gcc-only — no clang
  detected)` and a two-line note about what's disabled.
- README adds a "gcc-only mode" section with the feature matrix and
  `g:fakeide_compiler='gcc'` / `g:fakeide_has_clang=0` instructions.
- `docs/INSTRUCTIONS.md` §2.4 updated to call out the runtime detection and
  the override knob.

**Key decisions / gotchas:**
- **Name-based detection is wrong on macOS.** `/usr/bin/gcc` IS Apple clang.
  A naive check would let the clang-only paths run anyway (they'd succeed
  because gcc-named-clang accepts `-Xclang`). Probe via `--version` is the
  right test.
- **goto degrades to vimgrep, not to nothing.** Pressing `<C-]>` on a
  gcc-only machine opens a quickfix of textual candidates rather than
  silently failing. Less surprising; closer to "something useful happens."
- **Refs and diagnostics aren't gated** — they don't need clang. Pure
  -fsyntax-only (gcc has it) and pure vimgrep respectively.
- We can't truly run a "no clang" smoke test on this Mac (Apple `gcc` IS
  clang). The test forces the path via `g:fakeide_has_clang=0` before
  `fakeide#enable()` runs.

**Next:** unchanged from prior entries — PCH for completion speed, async
`complete()` auto-trigger, AST-walk refs ("Tier 4"). The gcc-only path
doesn't add anything to that list; it just makes the existing feature set
honest about what works without clang.

---

## 2026-06-05 — refs.vim: cheap project-wide references (`gr`)

**Done (verified against real Vim 8.0.0000 — 5/5 refs checks PASS):**
- `autoload/fakeide/refs.vim` — `fakeide#refs#find()` runs
  `vimgrep /\<<cword>\>/jg <root>/**/*.{c,h,cc,hh,cpp,hpp,cxx,hxx}`, opens
  the quickfix list, and echoes the hit count. Project-root heuristic mirrors
  `goto.vim`'s fallback (compile_commands.json / .fakeide / .git → first hit
  walking up; else the buffer's directory). Extension set shared with goto via
  `g:fakeide_goto_grep_exts`.
- `gr` (buffer-local, gated by `g:fakeide_refs_maps`) + `:FakeIdeReferences`.
  Wired into `fakeide#enable()`.
- `test/refs.vim` (5 checks: map wired, cross-file `compute_sum` hits, qflist
  opens, multi-hit Widget). Hooked into `test/run.sh` loop.
- DESIGN.md §5.7 documents the cheap-vs-accurate trade and the AST-walk
  alternative (saved for Tier 4 / polish — multi-second JSON parse is the
  blocker). TESTING.md gains a Tier 3 acceptance step for `gr`.

**Honest limits (intentional, per §5.7):**
- Textual match — catches comments, strings, similarly-named locals in
  unrelated scopes. No scope / type filtering. The AST walk in clang's full
  dump is the path to accurate refs and is the obvious follow-up if false
  positives prove annoying day-to-day.

**Exact command:** none — pure Vim `:vimgrep`. No clang invocation, no async
plumbing, no `:sleep`-poll. Synchronous and fast even on big trees.

**Heads-up:** `sh test/run.sh` currently reports `RESULT: FAIL` overall, but
not from refs — `test/fixtures/tier1/broken.c` was edited locally (the
`#warning` line and the `undeclared_sym` error removed) so Tier 1's diag test
correctly says "no error to find." The fixture change is the user's; left
in place per their instruction. Tier 1 will go green again the moment that
file is restored to its committed shape (`git checkout -- test/fixtures/tier1/broken.c`).

**Next:** unchanged — PCH for system headers (biggest completion / goto / info
speedup), save-only diagnostics for very heavy files, async `complete()`
auto-trigger (would also unblock auto-info on `CursorHold`), AST-walk refs
("Tier 4" — see DESIGN §5.7).

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
