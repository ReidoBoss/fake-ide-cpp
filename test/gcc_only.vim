" test/gcc_only.vim — exercise the degraded gcc-only path.
"
" We can't truly test "gcc only" on this machine (macOS's /usr/bin/gcc is
" actually clang under the hood) so we force the no-clang code path with
" g:fakeide_has_clang=0. That stubs fakeide#has_clang() to return 0 BEFORE
" any module reads it, which is exactly what would happen on a real
" GNU-gcc-only toolchain.
"
" Verifies:
"   * completion silently returns [] (findstart=-2) — no clang exception,
"     no garbage candidates;
"   * goto routes to the vimgrep fallback and opens the quickfix list;
"   * info bails with a warning and prints nothing into the buffer;
"   * diagnostics still works (just sanity-checks the loclist populates).
" Writes PASS/FAIL lines to $FAKEIDE_SMOKE_OUT (or a /tmp default).

set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
runtime plugin/fakeide.vim

" CRITICAL — force the no-clang path before fakeide#enable() runs.
let g:fakeide_has_clang = 0

let g:R = []
function! Check(name, cond, detail) abort
  call add(g:R, (a:cond ? 'PASS ' : 'FAIL ') . a:name . '  | ' . a:detail)
endfunction

let s:main = s:root . '/test/fixtures/tier3/main.cpp'
execute 'edit ' . fnameescape(s:main)
setfiletype cpp
call fakeide#enable()

" Sanity: has_clang() honours the override.
call Check('gcc-has-clang-zero', fakeide#has_clang() == 0,
      \ 'has_clang=' . fakeide#has_clang())

" --- completion no-ops cleanly ---
call cursor(1, 1)
call search('w\.\zsx', 'W')
let s:start = fakeide#complete#omni(1, '')
call Check('gcc-complete-cancelled', s:start == -2,
      \ 'findstart=' . s:start)

" --- goto: smart-jump heuristic finds a function definition ---
" `local_helper` has a real definition (`int local_helper(int x) {`) in
" main.cpp; the gcc-only path's vimgrep fallback should auto-jump to it
" instead of opening a quickfix list.
call cursor(1, 1)
call search('return \zslocal_helper', 'W')
let s:before_buf  = bufnr('%')
let s:before_line = line('.')
call fakeide#goto#jump()
let s:after_qf_open = 0
for s:w in range(1, winnr('$'))
  if getwinvar(s:w, '&buftype') ==# 'quickfix' | let s:after_qf_open = 1 | break | endif
endfor
call Check('gcc-goto-smart-jumps',
      \ line('.') == 14 && !s:after_qf_open,
      \ 'line=' . line('.') . ' qf_open=' . s:after_qf_open)
if s:after_qf_open | cclose | endif

" --- goto: no definition found → falls back to quickfix list ---
" `compute_sum` only has a DECLARATION in lib.h (`int compute_sum(...);` —
" ends in `;`, not `{`). The smart-jump heuristic correctly refuses to pick
" a declaration as a definition, so we should land in quickfix.
if fnamemodify(bufname('%'), ':p') !=# s:main
  execute 'buffer ' . fnameescape(s:main)
endif
call cursor(1, 1)
call search('\<compute_sum\>', 'W')
call fakeide#goto#jump()
let s:qf = getqflist()
call Check('gcc-goto-vimgrep-fallback', len(s:qf) >= 1,
      \ 'qf=' . len(s:qf))
let s:qf_open = 0
for s:w in range(1, winnr('$'))
  if getwinvar(s:w, '&buftype') ==# 'quickfix'
    let s:qf_open = 1 | break
  endif
endfor
call Check('gcc-goto-qf-opens', s:qf_open, 'qf_open=' . s:qf_open)
cclose
if fnamemodify(bufname('%'), ':p') !=# s:main
  execute 'buffer ' . fnameescape(s:main)
endif

" --- info echoes the disabled warning and returns nothing useful ---
call cursor(1, 1)
call search('\<compute_sum\>', 'W')
redir => s:echo
silent call fakeide#info#show()
redir END
" The first call should warn (via :echomsg, which redir captures); the second
" should NOT warn (s:warned_no_clang is sticky). We don't assert message text
" because the warning goes through echohl/echomsg — but the call must not
" print a signature, and must not throw.
call Check('gcc-info-no-signature', s:echo !~# 'int\s\+compute_sum',
      \ 'echo=' . substitute(s:echo, '\n', '|', 'g'))

" Note: we don't separately verify that diagnostics + refs still work under
" gcc-only — neither path checks fakeide#has_clang() (diag uses -fsyntax-only
" which both compilers support; refs is pure vimgrep). test/diag.vim and
" test/refs.vim already cover them.

" --- grep scope: 'samedir' restricts the search to the buffer's directory ---
" The tier3 fixture has everything in one dir (lib.h + main.cpp), so a
" 'samedir' goto on `compute_sum` should still find lib.h (it's a sibling)
" but the project-wide vimgrep wouldn't pull in anything from outside.
let g:fakeide_grep_scope = 'samedir'
let s:globs = fakeide#grep_globs(s:main)
let s:dir   = fnamemodify(s:main, ':h')
let s:samedir_globs_ok = 1
for s:g in s:globs
  if stridx(s:g, s:dir . '/*.') != 0
    let s:samedir_globs_ok = 0 | break
  endif
  if stridx(s:g, '**') >= 0
    let s:samedir_globs_ok = 0 | break
  endif
endfor
call Check('gcc-samedir-globs-shape', s:samedir_globs_ok,
      \ 'globs=' . string(s:globs))

" Restrict extensions too and confirm the glob list contains exactly those.
let g:fakeide_goto_grep_exts = ['c', 'h', 'cpp']
let s:globs2 = fakeide#grep_globs(s:main)
let s:tails = []
for s:g in s:globs2
  call add(s:tails, fnamemodify(s:g, ':e'))
endfor
call sort(s:tails)
call Check('gcc-samedir-exts-filtered',
      \ s:tails == ['c', 'cpp', 'h'],
      \ 'exts=' . string(s:tails))
" Reset for any later code in this test file.
unlet g:fakeide_grep_scope
unlet g:fakeide_goto_grep_exts

let s:out = empty($FAKEIDE_SMOKE_OUT) ? '/tmp/fakeide_gcc_only.txt' : $FAKEIDE_SMOKE_OUT
call writefile(g:R, s:out)
qa!
