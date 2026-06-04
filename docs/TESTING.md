# fake-ide — Manual Test / Acceptance Checklist

Run this by hand to confirm fake-ide works in real Vim 8.0 before accepting a
tier as done. For the automated suite, just run `sh test/run.sh` and look for
the final `RESULT: PASS`.

**Prerequisites**
- Vim 8.0 at `~/opt/vim80/bin/vim` (the project build).
- `clang` on your `PATH`.

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
