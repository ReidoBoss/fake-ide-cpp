# Progress Log

Newest entries at the top. One entry per finished unit of work. See
`docs/INSTRUCTIONS.md` §6 — updating this file is part of finishing a task.

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
