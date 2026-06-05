# fake-ide — Manual Test / Acceptance Checklist

Run this by hand to confirm fake-ide works in real Vim 8.0 before accepting a
tier as done. For the automated suite, just run `sh test/run.sh` and look for
the final `RESULT: PASS`.

**Prerequisites**
- Vim 8.0 at `~/opt/vim80/bin/vim` (the project build).
- `clang` on your `PATH`.

**Daily-use install (optional — needed only if you want fake-ide active on any
C/C++ file outside the repo, not just under `-Nu test/vimrc`).** Add this to
`~/.vimrc` (it is read by `vim80`; `nvim` reads its own config and is
unaffected):

```vim
set nocompatible
let s:fakeide = expand('~/Projects/fake-ide-cpp')
execute 'set runtimepath^=' . fnameescape(s:fakeide)
execute 'set runtimepath+=' . fnameescape(s:fakeide . '/after')
filetype plugin indent on
syntax on
set updatetime=300 signcolumn=yes completeopt=menuone,noinsert,noselect
set shortmess+=c hidden
```

The `+= ... /after` line matters — without it, Vim's bundled
`$VIMRUNTIME/ftplugin/{c,cpp}.vim` clobbers our `omnifunc` (`<C-x><C-o>` falls
back to the built-in `ccomplete#Complete` instead of fake-ide). Verify with
`vim80 some.cpp` → `:set omnifunc?` → should print `fakeide#complete#omni`.

---

## Quick automated pass

```sh
sh test/run.sh
```

Expect the last line to read `RESULT: PASS`. This exercises the async job
wrapper, compile-flag resolution, and the full diagnostics pipeline headlessly.

---

## Tier 1 — diagnostics (by hand)

1. Open the broken fixture:
   ```sh
   ~/opt/vim80/bin/vim -Nu test/vimrc test/fixtures/tier1/broken.c
   ```
2. Run `:version` — the first line must say **8.0**.
3. Diagnostics run automatically on open. Within a moment you should see:
   - [ ] a `W>` sign in the gutter on **line 6** (the `#warning` line)
   - [ ] an `E>` sign on **line 8** (`return undeclared_sym;`)
4. Run `:lopen`. The location list should show:
   - [ ] one **warning** ("fake-ide test warning") and one **error**
         ("use of undeclared identifier 'undeclared_sym'")
   - [ ] `]d` and `[d` jump the cursor between the two
5. Move the cursor onto line 8:
   - [ ] the error message echoes on the command line at the bottom of the screen
6. Live (unsaved) update — this proves the buffer is sent to clang on stdin, not
   read from disk:
   - press `o`, type `int x = nope;`, press `Esc` — **do not** `:w`
   - run `:FakeIdeCheck`
   - [ ] a new `E>` sign and location-list entry appear for that line, even
         though the file was never saved
7. Housekeeping commands:
   - [ ] `:FakeIdeClear` removes the signs and clears the location list
   - [ ] `:FakeIdeStatus` prints the resolved compiler and flags
   - [ ] `:FakeIdeFlags` includes `-Wall` (from `test/fixtures/tier1/.fakeide`)

If every box checks, Tier 1 is good.

**Troubleshooting:** if you see a one-time `compiler not found` warning instead
of signs, `clang` isn't on the `PATH` Vim inherited — check `:FakeIdeStatus`.

---

## Tier 2 — semantic completion (by hand)

1. Open the completion fixture:
   ```sh
   ~/opt/vim80/bin/vim -Nu test/vimrc test/fixtures/tier2/sample.cpp
   ```
   (`test/vimrc` already sets a usable `completeopt`.)
2. Member completion. Go to the `int a = p.x;` line, position the cursor just
   after the `.`, enter insert mode, and press **`CTRL-X CTRL-O`** (or run
   `:FakeIdeComplete`). Within a moment (clang parses the TU — brief pause is
   expected, see below):
   - [ ] a popup menu lists the `Point` members: **`dist`, `move`, `x`, `y`**
         (plus `operator=`, `Point`, `~Point`)
   - [ ] the menu/preview shows **types and signatures**, e.g. `dist` → `double`
         and `double dist() const`; `move` → `void move(int dx, int dy)`
3. Prefix filtering. Type `p.di` then `CTRL-X CTRL-O`:
   - [ ] only **`dist`** is offered (clang filtered by the typed prefix `di`)
4. Live (unsaved) update — proves the buffer is sent to clang on stdin:
   - add a new member to `Point`, e.g. on its own line inside the struct type
     `int unsaved_member;`, and **do not** `:w`
   - back at a `p.` site, `CTRL-X CTRL-O`
   - [ ] **`unsaved_member`** appears in the menu even though the file was never
         saved
5. Optional — auto-trigger. Add `let g:fakeide_complete_auto = 1` to your vimrc
   (or `:let g:fakeide_complete_auto=1` then reopen the buffer). Now typing `.`,
   `->`, or `::` after an identifier pops the menu automatically.
   - [ ] typing `p.` opens the member menu without pressing `CTRL-X CTRL-O`

**Expected feel / blocking note:** completion is **synchronous** — Vim 8.0 has no
non-blocking completion API, so the editor pauses briefly (the clang parse, ~100ms
to ~1s+ on heavy C++) while the menu is built. This only happens on an explicit
completion (or on `.`/`->`/`::` when auto-trigger is on), never on every
keystroke. It's the documented "no daemon" cost. If a completion takes too long
it aborts after `g:fakeide_complete_timeout` ms (default 3000) and shows nothing.

**Troubleshooting:** empty menu / "Pattern not found"? Check `:FakeIdeStatus`
shows `compiler=clang` and sensible flags — wrong/missing `-I`/`-std` flags yield
no candidates. Completion needs **clang** (gcc has no `-code-completion-at`); if
`g:fakeide_compiler` points at gcc, diagnostics work but completion won't.

If every box checks, Tier 2 is good.

---

## Tier 3 — go-to-definition + type info (by hand)

1. Open the Tier 3 fixture:
   ```sh
   ~/opt/vim80/bin/vim -Nu test/vimrc test/fixtures/tier3/main.cpp
   ```
2. **Cross-file go-to-definition.** Move the cursor onto `compute_sum` (line 22)
   and press `<C-]>` (or `:FakeIdeJump`). Brief pause (clang parse — same
   "no daemon" cost as Tier 2):
   - [ ] the buffer switches to **`lib.h`** and the cursor lands on the
         declaration at **line 5**
   - [ ] `<C-t>` (or `:FakeIdeBack`) returns to `main.cpp` at the original
         cursor position
3. **Same-file go-to-definition.** Cursor onto `local_helper` (line 23),
   `<C-]>`:
   - [ ] cursor jumps to the definition at **line 14** (same buffer)
   - [ ] `<C-t>` returns
4. **Unsaved decls jump too** (proves the buffer is sent on stdin). Add a new
   function above `main` without saving:
   ```cpp
   int unsaved_decl() { return 0; }
   ```
   Insert a call `unsaved_decl();` inside `main`, position the cursor on the
   call, `<C-]>`:
   - [ ] jumps to the new (unsaved) definition
5. **Vimgrep fallback.** Type a probe line `// probe: nonsense_xyz here.`, put
   the cursor on `nonsense_xyz`, `<C-]>`:
   - [ ] AST returns nothing, the quickfix list opens with vimgrep matches
         (likely empty for a truly nonexistent name) — no silent jump
6. **Type / signature info (`K`).** Cursor onto various names, press `K` (or
   `:FakeIdeInfo`):
   - [ ] on `w.width` (line 20) → command-line echoes **`int width`**
   - [ ] on `w.area()` (line 22) → echoes **`int area() const`**
   - [ ] on `compute_sum` (line 22) → echoes **`int compute_sum(int a, int b)`**
7. **Preview-window variant.** `:let g:fakeide_info_in_preview=1`, then `K` on
   any of the names:
   - [ ] a small preview window opens with the signature instead of echoing

**Expected feel / blocking note:** like Tier 2, `<C-]>` and `K` are
**synchronous** — clang parses the TU each time (~100ms–1s+). The pause only
happens on the keypress, never on idle. If a jump or info call takes too long
it aborts after `g:fakeide_goto_timeout` / `g:fakeide_info_timeout` ms.

**Troubleshooting:** `<C-]>` silently doing nothing on a known-good symbol? Run
`:FakeIdeStatus` and check `compiler=clang`. The `-ast-dump-filter` flag needs
clang; goto via gcc isn't supported. If `:FakeIdeFlags` is missing your `-I`
paths, definitions in headers won't be found.

If every box checks, Tier 3 is good.

---

## Reference: the exact compiler command

Diagnostics shell out to (buffer piped on stdin):

```
clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
      -x c <flags from flags.vim> -I<file's dir> -
```

(`-x c++` for C++ buffers.) See `docs/DESIGN.md` §5.3 for the full pipeline.

Completion (Tier 2) shells out to (buffer piped on stdin, cursor at `L:C`):

```
clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
      -x c++ -Xclang -code-completion-at=-:L:C <flags from flags.vim> -I<file's dir> -
```

It parses the `COMPLETION:` lines from stdout. See `docs/DESIGN.md` §5.4.

Go-to-definition (Tier 3) shells out to:

```
clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
      -Xclang -ast-dump=json -Xclang -ast-dump-filter=<sym> \
      -x c++ <flags from flags.vim> -I<file's dir> -
```

It parses clang's stream of top-level JSON objects, enforces exact `name == sym`
(the filter is prefix-matched), and reads `loc.file` / `loc.line` / `loc.col`
off the matched `*Decl` node. See `docs/DESIGN.md` §5.5.
