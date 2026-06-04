# Progress Log

Newest entries at the top. One entry per finished unit of work. See
`docs/INSTRUCTIONS.md` §6 — updating this file is part of finishing a task.

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
