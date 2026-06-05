# fake-ide

C/C++ IntelliSense for **Vim 8.0**, written entirely in Vimscript and driven
by the system `clang` you already have installed. No plugins, no plugin
managers, no LSP server, no `ctags`, no `libclang`, no Neovim — just Vim
and the compiler.

## What you get

| Feature | Key | Driven by |
|---|---|---|
| Live diagnostics (signs + location list + cursor echo) | `:w` + idle | `clang -fsyntax-only` |
| Semantic completion (member, scope, type-aware) | `<C-x><C-o>` (or auto after `.` / `->` / `::`) | `clang -Xclang -code-completion-at` |
| Go-to-definition | `<C-]>` / `:FakeIdeJump` | `clang -Xclang -ast-dump=json -ast-dump-filter` |
| Type / signature info | `K` / `:FakeIdeInfo` | clang code-completion (reused) |
| Project-wide references | `gr` / `:FakeIdeReferences` | `:vimgrep` over project root |

The design goal is to feel like an IDE in real Vim 8.0 — gutter signs, the
native insert-mode popup, location/quickfix lists, command-line echoes — with
zero non-compiler dependencies. Trade-off: each completion / jump / info
spawns a fresh clang process, so it's slower than clangd (~100ms–1s).
See [`docs/DESIGN.md`](docs/DESIGN.md) §10 for the honest cost discussion.

## Requirements

- **Vim 8.0 or newer** with `+job +channel +timers +signs +quickfix`.
  - Completion uses `clang -code-completion-at` so the popup menu requires
    `clang` specifically; diagnostics work with either `clang` or `gcc`.
  - If you're stuck on an older Vim, build 8.0.0000 from source — the recipe
    is in [`docs/PROGRESS.md`](docs/PROGRESS.md) (2026-06-04 entry).
- **`clang`** on `$PATH` for the full feature set. With **gcc only** you
  still get diagnostics + references — completion / goto / type-info are
  clang-only (gcc has no `-code-completion-at` or JSON `-ast-dump`); see
  the [gcc-only mode](#gcc-only-mode) section below.

## Install on a work machine

### 1. Clone the repo somewhere stable

```sh
mkdir -p ~/Projects
git clone https://github.com/ReidoBoss/fake-ide-cpp.git ~/Projects/fake-ide-cpp
```

### 2. Wire it into your Vim

Add this block to your `~/.vimrc` (create one if it doesn't exist). If you
already have a `~/.vimrc`, just append the marked lines.

```vim
" --- fake-ide: C/C++ IntelliSense for Vim 8.0 ---
" Adjust the path if you cloned somewhere other than ~/Projects/fake-ide-cpp.
let s:fakeide = expand('~/Projects/fake-ide-cpp')
execute 'set runtimepath^=' . fnameescape(s:fakeide)
" Important: the matching `+= .../after` line is required so our
" after/ftplugin/{c,cpp}.vim overrides Vim's bundled ftplugin and keeps
" omnifunc pointed at fakeide#complete#omni.
execute 'set runtimepath+=' . fnameescape(s:fakeide . '/after')

set nocompatible
filetype plugin indent on
syntax on

" IDE-ish defaults (all Vim 8.0-safe).
set number                                  " line numbers on the left
set updatetime=300                          " snappier idle diagnostics
set signcolumn=auto                         " sign gutter only when a sign is placed
                                            "   (use `yes` to reserve the column
                                            "   permanently — avoids the code shifting
                                            "   right when an error first appears)
set completeopt=menuone,noinsert,noselect   " usable insert-mode menu
set shortmess+=c                            " quiet completion messages
set hidden

" Optional — fire the completion popup automatically after . / -> / ::.
" Synchronous: briefly blocks while clang parses (~100ms–1s). Comment out
" if you'd rather press <C-x><C-o> manually.
let g:fakeide_complete_auto = 1

" Optional — LSP-style key bindings on C/C++ buffers only.
"   gd → go-to-definition in a new tab (`:q` returns to the previous tab)
"   gD → pop fake-ide's internal jump stack
" The built-in <C-]> / <C-t> / K / gr still work too.
augroup fakeide_lsp_keys
  autocmd!
  autocmd FileType c,cpp nnoremap <silent> <buffer> gd :tab split <Bar> FakeIdeJump<CR>
  autocmd FileType c,cpp nnoremap <silent> <buffer> gD :FakeIdeBack<CR>
augroup END

" Optional — tab navigation. <Tab> next tab, Shift-<Tab> previous.
" Caveat: in a terminal <Tab> and <C-i> are the same key, so this overrides
" Vim's built-in <C-i> ("jump forward in the jumplist"). Comment out and use
" `gt` / `gT` if you rely on <C-i>.
nnoremap <silent> <Tab>   :tabnext<CR>
nnoremap <silent> <S-Tab> :tabprev<CR>
```

### 3. Verify

Open any C/C++ file and check:

```vim
:FakeIdeStatus
```

Should print `compiler=clang`, the resolved flag source (`compile_commands.json`
/ `.fakeide` / `defaults`), and the flag list. If it does, you're done.

```vim
:set omnifunc?
```

Should print `omnifunc=fakeide#complete#omni`. If it shows `ccomplete#Complete`,
the `runtimepath+=...after` line is missing or wrong.

## gcc-only mode

If your machine doesn't have clang, fake-ide detects that automatically and
degrades gracefully. The probe runs once per session — it reads
`<compiler> --version` and looks for the word `clang` in the output (Apple's
`gcc` is actually clang, GNU's isn't).

| Feature | clang | gcc-only |
|---|---|---|
| Diagnostics (`:w` + idle) | ✅ | ✅ |
| References (`gr`) | ✅ | ✅ |
| Go-to-definition (`<C-]>` / `gd`) | ✅ AST-precise | ⚠️ smart-jump: heuristic vimgrep that auto-jumps to a definition-shaped line (`NAME(...) {` or `struct NAME {…}`) when it can; falls to quickfix only if nothing looks like a definition |
| Completion (`<C-x><C-o>`) | ✅ | ❌ silent no-op + one-shot warning |
| Type info (`K`) | ✅ | ❌ warning + bail |

Set `let g:fakeide_compiler = 'gcc'` in your `~/.vimrc` to point diagnostics
at gcc (otherwise the default `clang` will fail-to-find on a machine without
it). To force the gcc-only path for testing even when clang IS installed:
`let g:fakeide_has_clang = 0`.

`:FakeIdeStatus` shows whether clang features are active and what's been
disabled.

The fix for the missing 60% is to install clang from your distro's package
repo (`apt install clang`, `yum install clang`, `xcode-select --install` on
macOS) — it's a system toolchain package, not "third party" per
[`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md) §2.

## Telling fake-ide where your headers are

fake-ide resolves compile flags per file, in this order
([`docs/DESIGN.md`](docs/DESIGN.md) §5.1):

1. **`compile_commands.json`** at any ancestor directory. If your build emits
   it (CMake: `set(CMAKE_EXPORT_COMPILE_COMMANDS ON)`), you're done — fake-ide
   matches each source file to its entry and lifts `-I`/`-D`/`-std`.
2. **`.fakeide`** — a flat flags file at any ancestor directory:
   ```
   -std=c++17
   -I./include
   -I./third_party
   -DDEBUG
   -Wall
   ```
3. **Built-in defaults** — `-std=c++17` (cpp) / `-std=c11` (c) plus the
   source's own directory as an include path.

Run `:FakeIdeFlags` on any open buffer to see the resolved flags; reload after
edits with `:FakeIdeReloadFlags`.

## Try it without installing

There's a small playground in [`examples/playground/`](examples/playground/)
with a header + impl + driver that exercises all five features. After cloning:

```sh
cd ~/Projects/fake-ide-cpp
vim -Nu test/vimrc examples/playground/main.cpp
```

The header comment at the top of `main.cpp` lists exactly which keys to press
for each tier.

## Commands and default key bindings

| Command | Default key | What it does |
|---|---|---|
| `:FakeIdeStatus` | — | Show compiler, flag source, resolved flags |
| `:FakeIdeFlags` | — | Print the resolved flags for the current buffer |
| `:FakeIdeReloadFlags` | — | Clear the cached flags / `compile_commands.json` |
| `:FakeIdeCheck` | save + idle | Run diagnostics now for the current buffer |
| `:FakeIdeClear` | — | Clear gutter signs + location list |
| `:FakeIdeComplete` | `<C-x><C-o>` (insert) | Trigger semantic completion |
| `:FakeIdeJump` | `<C-]>` | Go to definition |
| `:FakeIdeBack` | `<C-t>` | Pop fake-ide's jump stack |
| `:FakeIdeInfo` | `K` | Echo type / signature for word under cursor |
| `:FakeIdeReferences` | `gr` | Project-wide references → quickfix |

Diagnostics also map `]d` / `[d` to `:lnext` / `:lprev`.

## Honest limits

- **Completion is synchronous.** Each pop = a fresh clang TU parse, so the
  editor blocks for ~100ms–1s. Manual trigger is the default; auto-trigger
  (`.` / `->` / `::`) is opt-in via `g:fakeide_complete_auto`.
- **Diagnostics don't update on every keystroke** by default — only on save
  and idle. Toggle via `g:fakeide_diag_on_insert`.
- **References is textual** (`vimgrep \<sym\>`), not scope-aware — it'll
  catch comments and same-named locals in unrelated scopes. Accurate refs
  would need an AST walk; see [`docs/DESIGN.md`](docs/DESIGN.md) §5.7.
- **No popups / floats / virtual text.** Vim 8.0 doesn't have them — we use
  the sign column, command-line echo, location/quickfix lists, and `:pedit`
  preview windows instead.
- **Doesn't replace clangd.** If you can use clangd, you should. fake-ide
  exists for environments where you can't — see [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md) §2.

## Docs

- [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md) — the rules every agent
  (Claude Code, Codex) and contributor must follow.
- [`docs/DESIGN.md`](docs/DESIGN.md) — architecture, per-component design,
  build plan, risks, open questions.
- [`docs/TESTING.md`](docs/TESTING.md) — by-hand acceptance checklist.
- [`docs/PROGRESS.md`](docs/PROGRESS.md) — dated log of what shipped when.

## Test it

```sh
sh test/run.sh
```

Headless suite under a real pty (job/channel callbacks need it). Expects
`RESULT: PASS`.
