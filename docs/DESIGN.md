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
- Collect stdout/stderr via `out_cb`/`err_cb` (or `close_cb` for batch).
- Track the running job per buffer; **kill the previous job** (`job_stop`) when a
  newer request supersedes it (debounced typing → only the latest matters).
- Timeout guard via `timer_start`.

This isolates every other component from raw channel plumbing.

### 5.3 `diag.vim` — diagnostics (Tier 1)

**Trigger:** `BufWritePost` (always) and debounced `CursorHold` / `TextChangedI`
(optional, configurable — heavy files may want save-only).

**Command:**
```
clang -fsyntax-only -fno-color-diagnostics \
      -fdiagnostics-print-source-range-info \
      <flags from flags.vim> <file>
```
(`gcc` works identically with the same flags if the user prefers it.)

**Pipeline:**
1. Run async via `job.vim`.
2. On completion, parse `errorformat`-style lines:
   `file:line:col: error: message` / `... warning: ...` / `note:`.
   Vim's `getqflist({'lines': ...})` with a custom `errorformat` does the parsing
   for us — no manual regex needed.
3. Populate the **location list** (per-window, so each file keeps its own).
4. Place **signs** in the gutter: `E>` red for errors, `W>` yellow for warnings.
5. On `CursorHold`, if the cursor sits on a diagnostic line, **echo** the message
   to the command line (our "hover" substitute).

**Debounce:** `timer_start(300, ...)`; restart the timer on each change so we only
compile ~300ms after the user stops typing.

### 5.4 `complete.vim` — semantic completion (Tier 2)

This is the hardest and highest-value piece.

**Wiring:** `set omnifunc=fakeide#complete#Omni`. Triggered manually with
`C-x C-o`, and auto-triggered after `.`, `->`, `::` via an `InsertCharPre` /
mapping that fires `omnifunc`.

**Command (the key technique):**
```
clang -fsyntax-only -x c++ \
      -Xclang -code-completion-at=-:LINE:COL \
      <flags> -
```
- We pass `-` so clang reads the **translation unit from stdin** → we send the
  **current unsaved buffer**, so completion reflects what's on screen, not the
  last save.
- `-:LINE:COL` tells clang to complete at that position in the stdin input.

**Output parsing:** clang prints lines like:
```
COMPLETION: push_back : [#void#]push_back(<#const value_type &__x#>)
COMPLETION: size : [#size_type#]size()
```
We parse: candidate name, return type (`[#...#]`), and argument placeholders
(`<#...#>`). These map directly to Vim's completion item dict
(`word`, `menu`, `info`, `kind`) for a rich popup menu.

**Two-call protocol** (matches Vim's omnifunc contract):
1. First call (`a:findstart == 1`): return the column where the partial word
   begins.
2. Second call: return the list of completion dicts.

**Latency mitigation** (the known weak spot vs. a daemon):
- Debounce; kill superseded jobs.
- Precompiled headers (PCH) for the project's big/stable system headers
  (`clang -x c++-header foo.h -o foo.h.pch`, then `-include-pch`), cutting
  per-keystroke parse time dramatically.
- Cache the last completion result for the same position.

> **Honest expectation:** each completion spawns a clang process that parses the
> TU. With PCH this is typically 100–400ms on moderate files; large C++ with
> heavy templates can hit 1s+. It will feel slower than clangd. That is the
> documented cost of "no daemon / no third party."

### 5.5 `goto.vim` — go-to-definition (Tier 3)

Vim 8.0 has no LSP `textDocument/definition`. Two viable approaches, no ctags:

- **Compiler-assisted (preferred):** use clang's AST dump for the current file
  (`clang -Xclang -ast-dump=json -fsyntax-only`) parsed with `json_decode()` to
  locate the declaration of the symbol under the cursor. Heavier but accurate.
- **Heuristic fallback:** `vimgrep` across project files for the symbol's
  declaration/definition pattern, presented in the quickfix list. Fast, dumb,
  good enough for jumping around.

Jump with the standard tag stack semantics (`C-]` feel) so it's familiar.

### 5.6 `info.vim` — type info / signature (Tier 3)

Reuse the code-completion output (it carries return types and signatures) or a
targeted AST query at the cursor. Display via **command-line echo** and/or the
**preview window** (`:pedit`), since 8.0 has no hover popups.

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

1. **Diagnostics frequency:** on-save only, or also debounced while typing?
   (Affects CPU on large files.)
2. **Completion compiler:** confirm **clang** is acceptable for completion (gcc
   can't do `-code-completion-at`); gcc remains fine for diagnostics.
3. **PCH:** are we allowed to write `.pch` cache files into the project/tmp dir?
4. **Flags source:** does the build already emit `compile_commands.json`? If not,
   we standardize on a `.fakeide` flags file per project.
5. **Install location:** per-user `~/.vim/` vs. a checked-in, project-local
   `runtimepath` directory (better for team consistency and review).
