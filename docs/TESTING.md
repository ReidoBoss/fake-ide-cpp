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

## Reference: the exact compiler command

Diagnostics shell out to (buffer piped on stdin):

```
clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
      -x c <flags from flags.vim> -I<file's dir> -
```

(`-x c++` for C++ buffers.) See `docs/DESIGN.md` §5.3 for the full pipeline.
