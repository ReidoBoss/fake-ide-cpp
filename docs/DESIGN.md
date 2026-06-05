# fake-ide: C/C++ IntelliSense for Vim 8.0 — Design Document

**Status:** Proposal / for review
**Author:** (you)
**Date:** 2026-06-04
**Target editor:** Vim 8.0 (hard requirement — no newer version available)
**Languages:** C and C++

---

## 1. Goal

Provide a modern-IDE editing experience ("fake Neovim") for C and C++ inside
**Vim 8.0**, including:

- Live diagnostics (errors/warnings) as you edit
- Semantic, type-aware code completion (members, methods, overloads)
- Go-to-definition and type/signature info
- Sensible IDE-like defaults

…implemented **entirely in Vimscript**, driving **only the compilers the
company already ships** (`clang`, `gcc`). No plugins, no plugin managers, no
third-party libraries, no language servers, no external downloads.

---

## 2. Compliance statement ("no third party")

This is the core constraint, so we state explicitly what we depend on:

| Dependency | Source | Third party? |
|---|---|---|
| Vim 8.0 | Already installed, company-approved | No |
| `clang` / `gcc` | Already installed build toolchain | No |
| Vimscript (the config we write) | Written in-house, this project | No |
| **clangd / ccls / LSP** | — | **NOT USED** |
| **ctags / Universal Ctags** | — | **NOT USED** |
| **Any vim plugin / pack / repo** | — | **NOT USED** |
| **libclang (linked C library)** | — | **NOT USED** |

The only "intelligence" comes from invoking the compiler **as a normal
command-line process** — the same binary already used to build the product.
We use two documented compiler features:

- `clang ... -Xclang -code-completion-at=FILE:LINE:COL` → semantic completion
- `clang -fsyntax-only` / `gcc -fsyntax-only` → diagnostics

Both are built-in compiler flags, not add-ons.

---

## 3. Hard constraints from Vim 8.0

Vim 8.0 (released 2016) is missing features that later versions use for IDE UX.
The design works **around** these — they are not available to us:

| Feature | Introduced in | Our substitute |
|---|---|---|
| Popup windows (`popup_*`) | 8.1.1 | Preview window (`:pedit`) + command-line echo |
| Text properties / virtual text | 8.1 | Sign column + location list |
| `prop_add` inline diagnostics | 8.1 | Signs (gutter) + `:lopen` |
| Floating hover | 8.2+ | Echo type info on the command line |

What Vim 8.0 **does** give us (and what the whole design rests on):

- **Async jobs & channels** (`job_start`, `ch_sendraw`, `ch_read`, callbacks) —
  the headline 8.0 feature. Lets us run the compiler in the background without
  freezing the editor.
- **Insert-mode completion menu** (`completefunc`/`omnifunc`, `pumvisible()`) —
  works fully in 8.0.
- **Signs**, **quickfix/location lists**, **autocommands**, `timer_start`
  (debouncing), `:packadd`-free `autoload/` lazy loading.

---

## 4. Architecture overview

```
                        Vim 8.0 (Vimscript only)
   ┌─────────────────────────────────────────────────────────────┐
   │  ftplugin/c.vim, cpp.vim                                      │
   │    set omnifunc, completefunc                                 │
   │    autocmds: BufWritePost, CursorHold, TextChangedI           │
   └───────────────┬───────────────────────────┬─────────────────┘
                   │                           │
        ┌──────────▼─────────┐      ┌──────────▼──────────┐
        │ autoload/fakeide/  │      │ autoload/fakeide/   │
        │   complete.vim     │      │   diag.vim          │
        │ (omnifunc)         │      │ (async diagnostics) │
        └──────────┬─────────┘      └──────────┬──────────┘
                   │                           │
        ┌──────────▼───────────────────────────▼──────────┐
        │            autoload/fakeide/job.vim              │
        │   thin wrapper over job_start / ch_* / callbacks │
        └──────────┬───────────────────────────────────────┘
                   │  spawns processes (async)
        ┌──────────▼──────────┐   ┌──────────────────────┐
        │ clang -code-         │   │ clang/gcc            │
        │   completion-at=...  │   │   -fsyntax-only      │
        │ (reads buffer stdin) │   │ (diagnostics)        │
        └─────────────────────┘   └──────────────────────┘
                   ▲
        ┌──────────┴──────────┐
        │ autoload/fakeide/   │
        │   flags.vim         │  reads compile_commands.json or .fakeide
        └─────────────────────┘
```

### Directory layout

```
~/.vim/                              (or a project-local runtimepath dir)
├── ftplugin/
│   ├── c.vim                        wire up C buffers
│   └── cpp.vim                      wire up C++ buffers
├── after/
│   └── ftplugin/
│       ├── c.vim                    re-assert our omnifunc after Vim's built-in
│       └── cpp.vim                  re-assert our omnifunc after Vim's built-in
├── autoload/
│   └── fakeide/
│       ├── job.vim                  async job wrapper (job_start/ch_*)
│       ├── flags.vim                resolve compile flags per file
│       ├── diag.vim                 diagnostics engine → signs + loclist
│       ├── complete.vim             omnifunc → clang code-completion
│       ├── goto.vim                 go-to-definition
│       └── info.vim                 type info / signature on cursor
├── plugin/
│   └── fakeide.vim                  commands, signs definitions, defaults
└── DESIGN.md                        this file

To get `after/` semantics, the user's `~/.vimrc` (or `test/vimrc`) must add BOTH
the project root (prepended) AND `<root>/after` (appended) to `runtimepath` —
the standard pathogen/vim-plug convention. Without the `+=...after` step, Vim's
`runtime!` walk only finds `<root>/ftplugin/cpp.vim`, after which
`$VIMRUNTIME/ftplugin/cpp.vim` runs and clobbers our `setlocal omnifunc`.
```

We keep almost everything in `autoload/` so Vimscript lazy-loads it only when a
C/C++ buffer is opened (no startup cost).

---

## 5. Component design

### 5.1 `flags.vim` — compile flags resolution (do this FIRST)

**Why it matters most:** completion and diagnostics are worthless without the
correct `-I` include paths, `-std=`, and `-D` defines. Garbage flags → garbage
results. This is the #1 determinant of quality.

Resolution order, per source file:

1. **`compile_commands.json`** at the project root, if present. Clang and CMake
   emit this natively (`-MJ` flag / `CMAKE_EXPORT_COMPILE_COMMANDS`). We parse it
   with `json_decode()` (built into Vim 8.0) and match the file's entry. This is
   *not* a third-party file format — it is clang's own output.
2. **`.fakeide`** project file (our own simple format) — a flat list of flags,
   e.g. `-std=c++17 -I./include -I./third_party/foo -DDEBUG`.
3. **Fallback defaults**: `-std=c++17` (cpp) / `-std=c11` (c), plus the file's
   own directory as an include path.

Flags are **cached** per directory and invalidated on `:FakeIdeReloadFlags`.

### 5.2 `job.vim` — async process wrapper

A thin layer over Vim 8.0's `job_start()`:

- Start a job with `in_io: 'pipe'` so we can feed the live (unsaved) buffer to
  the compiler's stdin.
- Collect stdout/stderr via `out_cb`/`err_cb`.
- Track the running job per `tag`; **kill the previous job** (`job_stop`) when a
  newer request supersedes it (debounced typing → only the latest matters).
- Timeout guard via `timer_start`.

This isolates every other component from raw channel plumbing.

**Completion model (decided in Tier 0, verified against Vim 8.0):** we finish a
run on **`close_cb`** (channel drained = all output read), *not* on `exit_cb`.
Testing showed `exit_cb` timing is unreliable — it can lag or not fire within
seconds even after the process is dead, while `close_cb` and `out_cb` fire
promptly. The exit code is taken from `exit_cb` when available, otherwise read
from `job_info().exitval` once the process is reaped (polled briefly via a 10ms
timer, ~3s ceiling). Consequences captured in tests:
- List-form `stdin` is newline-terminated, or the final line is dropped in
  `nl` mode.
- Async/job behavior must be tested in a **real pty** (`script -q /dev/null …`);
  plain `vim -es` does not pump job/channel callbacks. See `test/run.sh`.
- **stderr must be merged into stdout** (`err_io: 'out'`), and `job.vim` does
  this by default (`merge_stderr`, on by default). With two separate pipes, a
  process that writes *only* to stderr (empty stdout) EOFs stdout instantly;
  `close_cb` then fires and we finalize **before** the buffered stderr is
  delivered, silently losing it. `clang -fsyntax-only` is exactly this case
  (diagnostics → stderr, stdout empty), so without the merge Tier 1 saw zero
  diagnostics. Verified on Vim 8.0.0000. Result: everything arrives in
  `result.out`; `result.err` stays empty unless a caller opts out with
  `merge_stderr=0`.

### 5.3 `diag.vim` — diagnostics (Tier 1) — IMPLEMENTED

**Trigger:** `BufWritePost` (always) and debounced `CursorHold` (idle, on by
default) / `TextChangedI` (while typing, off by default — heavy files may want
save+idle only). All configurable via `g:fakeide_diag_*`.

**Command (buffer fed on stdin, so unsaved edits are reflected):**
```
clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
      -x <c|c++> <flags from flags.vim> -I<file's dir> -
```
- The current buffer is sent on **stdin** (`-`) so diagnostics reflect what's on
  screen, not the last save. clang reports the unit as `<stdin>`; we map that
  back to the buffer. Errors inside `#include`d headers keep their real path and
  land in the location list (no sign in the editing buffer).
- `-I<file's dir>` keeps quoted-`#include` resolution working (stdin has no
  directory of its own, so clang would otherwise resolve against cwd).
- `-fno-caret-diagnostics` suppresses the source/caret lines, leaving one clean
  `file:line:col: severity: message` line per diagnostic.
- (`gcc` works identically with the same flags if the user prefers it.)

**Pipeline (as built):**
1. Run async via `job.vim` (tag `diag:<bufnr>`, so a newer run supersedes the
   stale one).
2. On completion, **parse manually** with `matchlist()`. We do *not* use
   `getqflist({'lines': ...})`: that dict form is a later 8.0.x patch and is
   **absent in the pinned 8.0.0000 build** (verified — it returns no items).
   Manual parsing also gives clean control over the `<stdin>` → buffer remap
   and over `fatal error` / `note` severities.
3. Populate the **location list** for a window showing the buffer (`setloclist`,
   per-window).
4. Place **signs** in the gutter (one per line; error wins over warning):
   `E>` (ErrorMsg) and `W>` (WarningMsg). 8.0.0000 has **no `sign_place()`
   function and no sign groups** (8.1+), so we use the `:sign place`/`:sign
   unplace` ex-commands and track placed ids in `b:fakeide_sign_ids`, unplacing
   them by id on each refresh.
5. On `CursorMoved`/`CursorHold`, if the cursor sits on a diagnostic line,
   **echo** the message (truncated to the command line) — our "hover" substitute.

**Mappings (buffer-local, gated by `g:fakeide_diag_maps`):** `]d` / `[d` →
`:lnext` / `:lprev`. **Commands:** `:FakeIdeCheck` (run now), `:FakeIdeClear`.

**Debounce:** `timer_start(g:fakeide_diag_debounce, ...)` (default 300ms),
restarted on each change so we only compile after the user pauses.

### 5.4 `complete.vim` — semantic completion (Tier 2) — IMPLEMENTED

This is the hardest and highest-value piece.

**Wiring:** `setlocal omnifunc=fakeide#complete#omni` (done in
`fakeide#complete#enable()`, called from `fakeide#enable()`). Manual trigger is
the native `i_CTRL-X_CTRL-O`; `:FakeIdeComplete` fires it for you. Auto-trigger
after `.`, `->`, `::` is available via `<expr>` insert-mode maps but is **opt-in**
(`g:fakeide_complete_auto`, default 0) — see the blocking note below.

**Command (the key technique, as built):**
```
clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
      -x <c|c++> -Xclang -code-completion-at=-:LINE:COL \
      <flags from flags.vim> -I<file dir> -
```
- We pass `-` so clang reads the **translation unit from stdin** → we send the
  **current unsaved buffer** (`getline(1,'$')`), so completion reflects what's on
  screen, not the last save (same stdin design as diagnostics §5.3).
- `-:LINE:COL` points clang at the **cursor** (the end of the typed partial), so
  **clang itself filters** candidates by the typed prefix. This is essential:
  pointing at the start of the word in a `std::` context dumps thousands of
  entries; pointing at the cursor returns only the matches. `findstart` returns
  the *start* of the partial so Vim replaces just the typed prefix.
- `-I<file dir>` mirrors §5.3 (stdin has no directory; keeps quoted `#include`
  resolution working). `COMPLETION:` lines go to **stdout**; diagnostics go to
  stderr. We use the default merged stream and filter `^COMPLETION:` lines, so
  diagnostic noise is ignored and the close_cb race (§5.2) is moot.

**Output parsing (as built):** clang prints two shapes —
```
COMPLETION: push_back : [#void#]push_back(<#const value_type &__x#>)
COMPLETION: x : [#int#]x
COMPLETION: __func__                         (macro/keyword — no signature)
COMPLETION: __padding (Inaccessible) : ...   (skipped)
```
We split name from signature on the **first ` : `**, drop `(Inaccessible)` /
`(Hidden)` candidates, extract the leading return type `[#...#]`, unwrap argument
placeholders `<#...#>`, optional segments `{#...#}`, and the trailing `[# const#]`.
Each becomes a Vim completion dict: `word` (the insertable identifier — operator
names kept whole, template/paren tails stripped), `menu` (return type),
`info` (full reconstructed signature), `kind` (`f` func / `v` var-or-member /
`t` type / `d` macro). Results are deduped by word+menu (distinct overloads
kept) and capped at `g:fakeide_complete_max` (default 200).

**Two-call protocol** (matches Vim's omnifunc contract):
1. First call (`a:findstart == 1`): return the byte column where the partial word
   begins **and snapshot `[line, col]`** — Vim's two calls must point clang at
   the same spot, and the cursor can differ between them, so the candidates call
   reuses the snapshot rather than re-reading `col('.')`.
2. Second call: run clang, parse, return the list of completion dicts.

**Async-but-synchronous (the key 8.0 constraint, decided in Tier 2):** Vim 8.0's
`omnifunc`/`completefunc` contract is **synchronous** — the function must *return*
the candidate list. Vim 8.0 has **no non-blocking completion API** short of the
`complete()` re-trigger hack (which flickers and fights the native menu). So the
omnifunc still runs clang through the async wrapper (`job.vim`, tag
`complete:<bufnr>`, superseding stale jobs) but then **waits on a bounded
`sleep`-poll loop** (`sleep 10m` until the `on_done` callback fires, capped at
`g:fakeide_complete_timeout`+500ms). `:sleep` is a point where Vim invokes
channel/job callbacks, so this works for real `i_CTRL-X_CTRL-O` (verified). The
consequence: completion **briefly blocks the UI** for the parse duration — but
only on an explicit completion request, never on every keystroke. This is the
documented "no daemon" latency cost (§10), and is why auto-trigger is opt-in. A
future enhancement could move auto-trigger to the async `complete()` path.

**Latency mitigation** (the known weak spot vs. a daemon):
- Kill superseded jobs (a fresh completion supersedes the in-flight one by tag).
- Cap the candidate count (`g:fakeide_complete_max`).
- Precompiled headers (PCH) for the project's big/stable system headers
  (`clang -x c++-header foo.h -o foo.h.pch`, then `-include-pch`) — **not yet
  implemented**; the highest-leverage future speedup.

> **Honest expectation:** each completion spawns a clang process that parses the
> TU. With PCH this is typically 100–400ms on moderate files; large C++ with
> heavy templates can hit 1s+. It will feel slower than clangd. That is the
> documented cost of "no daemon / no third party."

### 5.5 `goto.vim` — go-to-definition (Tier 3) — IMPLEMENTED

Vim 8.0 has no LSP `textDocument/definition`, and we forbid ctags. Two paths:

**Primary — compiler-assisted (as built):**
```
clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
      -Xclang -ast-dump=json -Xclang -ast-dump-filter=<symbol> \
      -x <c|c++> <flags from flags.vim> -I<file dir> -
```
- Buffer fed on stdin (same design as §5.3/§5.4) so unsaved decls are visible.
- `-ast-dump-filter=` is a **prefix match**, so the parser enforces exact
  `name == symbol`. clang emits a stream of top-level JSON objects (no array
  wrapper); we split on column-0 `{` … `}` boundaries and `json_decode()` each
  independently. From each matched object we read `loc.file` / `loc.line` /
  `loc.col`. `loc.file == "<stdin>"` means the current buffer. Implicit
  builtins prefix-matched by the filter have `loc: {}` and are skipped.
- Same-file matches win over cross-file; first match wins within each bucket.
  Only nodes whose `kind` ends in `Decl` are considered (`FunctionDecl`,
  `CXXMethodDecl`, `VarDecl`, `FieldDecl`, `CXXRecordDecl`, `EnumDecl`,
  `TypedefDecl`, …).

**Fallback — heuristic `vimgrep`:** triggered when the AST primary returns
nothing OR when running on a gcc-only toolchain (no `-Xclang -ast-dump=json`).
`vimgrep /\<sym\>/j` across C/C++ source extensions under the project root
(the nearest dir containing `compile_commands.json` / `.fakeide` / `.git`,
else the buffer's directory).

The hits then go through a **smart-jump heuristic** (`s:pick_definition`):

- **Type definition match:** a line of shape `(struct|class|enum|union) NAME`
  followed by `{`, `:` (base list), or end-of-line. Strongest signal — a type
  definition is unambiguous.
- **Function definition match:** `NAME(...)` (paren-balanced, no `;` inside
  the args) followed by `{` or end-of-line — with optional `const` /
  `noexcept` / `override` / `final` / trailing-return-type between the
  closing paren and the brace. Crucially this rejects `NAME(...);` (a
  declaration only).
- Within either bucket, prefer a `.cpp` / `.cc` / `.cxx` file over `.h` —
  definitions usually live in source files; declarations in headers.
- If exactly one bucket is non-empty and `s:prefer_source` returns a unique
  hit, **auto-jump** straight there (same UX as the AST path).
- Otherwise (no def-shaped hits at all, or genuinely ambiguous), open the
  quickfix list so the user picks.

The heuristic is a poor-man's ctags. False positives are possible (e.g. a
function-style macro that uses `NAME(args) { … }` shape would be picked),
but on real C/C++ the vast majority of `<sym>(...) {` lines are genuine
definitions. The escape hatch is `:cnext` / quickfix browsing if it lands
on the wrong line.

**Tag-stack:** Vim 8.0.0000 lacks `settagstack()`/`gettagstack()` (introduced in
8.0.1453). We keep our own script-local stack of `{bufnr, lnum, col, file}`;
`:FakeIdeJump` (`<C-]>`) pushes, `:FakeIdeBack` (`<C-t>`) pops. Buffer-local
mappings only, gated by `g:fakeide_goto_maps`.

**Synchronous wait (same constraint as Tier 2 — see §5.4 / §10):** jump runs
clang async via `job.vim` (tag `goto:<bufnr>`, supersede stale) then waits on a
bounded `:sleep 10m` poll loop, capped at `g:fakeide_goto_timeout`+500ms. A jump
is a one-shot user action, so the brief UI block is acceptable.

### 5.6 `info.vim` — type info / signature (Tier 3) — IMPLEMENTED

Reuses the Tier 2 completion mechanism rather than a separate AST query.

**How it works:**
- Read the cword and the start column of the identifier (same `\k`-scan as
  `complete.vim`'s `findstart`).
- Aim `clang -Xclang -code-completion-at=-:LINE:START_COL` at the **start** of
  the identifier so candidates come back with the typed prefix empty (rich
  result set), and find the entry whose `word == cword`.
- Re-unwrap the signature (same `[#ret#]` / `<#param#>` / `{#opt#}` / `[#
  const#]` handling as `complete.vim`'s `s:item`) and render
  `<ret> <signature>` via command-line echo. Truncated to fit one line — 8.0
  has no popups (§3).
- Optional `g:fakeide_info_in_preview` opens a small scratch preview window
  via `:pedit` instead (`nofile`, `bufhidden=wipe`).

**On-demand only.** Not wired to `CursorHold` — the same synchronous-blocking
constraint (§5.4) means autorun would block on idle. Triggered via `K`
(buffer-local, gated by `g:fakeide_info_maps`) and `:FakeIdeInfo`.

**Synchronous wait:** identical pattern to Tier 2 / goto — `job.vim` with tag
`info:<bufnr>`, bounded `:sleep`-poll, capped at `g:fakeide_info_timeout`+500ms.

### 5.7 `refs.vim` — project-wide references (cheap, textual) — IMPLEMENTED

The dumb-but-fast counterpart to §5.5's goto. Find references is the LSP move
that takes the most index work to do *accurately*; we explicitly do not do that
work and instead grep.

**How it works:**
- `<cword>` under the cursor (rejects non-identifiers).
- `s:project_root()` — same heuristic as goto.vim's fallback: walk up looking
  for `compile_commands.json` / `.fakeide` / `.git`; fall back to the buffer's
  directory if none found.
- `:vimgrep /\<sym\>/jg <root>/**/*.{c,h,cc,hh,cpp,hpp,cxx,hxx}` — extension
  set shared with goto's fallback via `g:fakeide_goto_grep_exts`. `j` keeps
  the cursor put; `g` collects multiple hits per line.
- Open quickfix (`copen`); echo `"N reference(s) to <sym>"` with the count.

**Honest limits (this is a 20% solution by design):**
- Textual match: catches comments, strings, and same-named locals in unrelated
  scopes.
- No type / scope filtering. Two unrelated classes both named `Point::dist`
  share one hit bucket.
- Doesn't dedupe overload sets, doesn't separate declarations from uses.

**Why not the AST walk.** The "accurate" version would `clang -ast-dump=json`
the whole TU (no filter), walk `DeclRefExpr` / `MemberExpr` / `CXXConstructExpr`
nodes by `referencedDecl.id` matching the target's id, and dedupe by `loc`.
Cost: heavy TU = MBs of JSON, and `json_decode` is multi-second under Vim.
That's a real tier of work (call it Tier 4) — open as a future "polish" item
in PROGRESS.md.

**Public:** `:FakeIdeReferences` / `gr` (buffer-local, gated by
`g:fakeide_refs_maps`). No async path needed — vimgrep is synchronous and
cheap.

---

## 6. UX in Vim 8.0 (what it actually looks like)

- **Errors/warnings:** colored signs in the gutter; `:lopen` for the full list;
  `]d` / `[d` mappings to jump between them; message echoed on the command line
  when the cursor rests on the offending line.
- **Completion:** the standard insert-mode popup menu (works natively in 8.0),
  with type and signature shown in the menu/info columns.
- **Go-to-def:** jumps like `C-]`, with `C-t` to pop back.
- **Type info:** echoed on the command line or shown in a preview window split.

No floating windows anywhere — every interaction uses gutter, command line,
location/quickfix list, or a split. This is a deliberate consequence of the 8.0
constraint, not an oversight.

---

## 7. Build plan & estimates (solo developer)

| Tier | Scope | Deliverable | Estimate |
|---|---|---|---|
| **0** | `job.vim` + `flags.vim` + IDE defaults | Async plumbing + flag resolution + sane settings | **2–4 days** |
| **1** | `diag.vim` | Live diagnostics: signs + location list, debounced | **3–5 days** |
| **2** | `complete.vim` | Semantic completion via `-code-completion-at` | **2–4 weeks** |
| **3** | `goto.vim`, `info.vim` | Go-to-def, type/signature info | **3–6 weeks** |
| **—** | Polish, PCH, caching, large-repo testing | Daily-driver quality | **+1–2 months** |

**Rough totals:** something genuinely useful in **~1–2 weeks** (Tiers 0–1);
real semantic completion in **~1.5–2 months**; polished IDE feel in **~6 months**
part-time.

Tiers are independently useful and shippable — Tier 1 alone is worth deploying.

---

## 8. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Wrong compile flags | Completion/diagnostics useless | Prioritize `flags.vim`; support `compile_commands.json` |
| Completion latency (no daemon) | Feels sluggish vs. clangd | PCH, debounce, kill stale jobs, cache |
| Vim 8.0 lacks popups | No inline/hover UI | Signs + loclist + command-line echo + preview window |
| Large C++ TUs slow to parse | 1s+ completions | PCH for system headers; save-only diagnostics mode |
| `gcc` lacks `-code-completion-at` | No GCC-based completion | Use **clang** for completion (gcc fine for diagnostics) |
| clang output format changes across versions | Parser breaks | Pin to company clang version; parse defensively |
| Macro-heavy / generated code | Misleading results | Honest limitation; rely on correct flags |

---

## 9. Explicit non-goals

- Not reimplementing a C++ parser/semantic analyzer by hand (person-years; this
  is exactly what we avoid by driving the compiler).
- Not matching clangd's instant, persistent-index responsiveness.
- Not supporting languages other than C/C++.
- No floating-window UI (impossible in 8.0).
- No background daemon/server (would blur the "no third party" line and adds ops
  burden); we spawn short-lived compiler processes instead.

---

## 10. Open questions for review

1. **Diagnostics frequency:** ~~on-save only, or also debounced while typing?~~
   **Decided (Tier 1):** `BufWritePost` always + debounced `CursorHold` (idle)
   on by default; `TextChangedI` (every keystroke) off by default. All toggleable
   via `g:fakeide_diag_on_idle` / `g:fakeide_diag_on_insert` for heavy files.
2. ~~**Completion compiler:** confirm **clang** is acceptable for completion (gcc
   can't do `-code-completion-at`); gcc remains fine for diagnostics.~~
   **Decided (Tier 2):** completion uses **clang** (`-Xclang -code-completion-at`).
   `g:fakeide_compiler` still drives it; pointing it at gcc would disable
   completion (no such flag) while diagnostics keep working.
3. **PCH:** are we allowed to write `.pch` cache files into the project/tmp dir?
4. **Flags source:** does the build already emit `compile_commands.json`? If not,
   we standardize on a `.fakeide` flags file per project.
5. **Install location:** per-user `~/.vim/` vs. a checked-in, project-local
   `runtimepath` directory (better for team consistency and review).
