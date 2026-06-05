" test/goto.vim — headless Tier 3 go-to-definition test. Run via test/run.sh.
" Verifies: clang AST-dump JSON round-trip parsed into a Decl loc; cross-file
" jump (header) and same-file jump; that exact-name (not prefix) match is
" enforced; that :FakeIdeBack restores the prior position. Must run in a pty
" so job/channel callbacks are pumped, AND because the jump waits on a
" sleep-poll loop (mirroring Tier 2; see test/run.sh).
" Writes PASS/FAIL lines to $FAKEIDE_SMOKE_OUT (or a /tmp default).

set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
runtime plugin/fakeide.vim

let g:R = []
function! Check(name, cond, detail) abort
  call add(g:R, (a:cond ? 'PASS ' : 'FAIL ') . a:name . '  | ' . a:detail)
endfunction

let s:main = s:root . '/test/fixtures/tier3/main.cpp'
let s:hdr  = s:root . '/test/fixtures/tier3/lib.h'
execute 'edit ' . fnameescape(s:main)
setfiletype cpp
call fakeide#enable()

" --- C-] mapping is wired on the buffer ---
let s:map = maparg('<C-]>', 'n', 0, 1)
call Check('goto-map-wired', !empty(s:map) && get(s:map, 'buffer', 0) == 1,
      \ 'map=' . string(s:map))

" --- cross-file jump: cursor on `compute_sum` in main.cpp → lib.h:5 ---
call cursor(1, 1)
call search('\<compute_sum\>', 'W')
let s:from = [bufnr('%'), line('.'), col('.')]
call fakeide#goto#jump()
call Check('goto-crossfile-buffer', fnamemodify(bufname('%'), ':p') ==# s:hdr,
      \ 'buf=' . bufname('%'))
call Check('goto-crossfile-line', line('.') == 5,
      \ 'lnum=' . line('.') . ' col=' . col('.'))

" --- back: restore to main.cpp at the original cursor ---
call fakeide#goto#back()
call Check('goto-back-buffer', fnamemodify(bufname('%'), ':p') ==# s:main,
      \ 'buf=' . bufname('%'))
call Check('goto-back-pos',
      \ line('.') == s:from[1] && col('.') == s:from[2],
      \ 'pos=' . line('.') . ':' . col('.') . ' want=' . s:from[1] . ':' . s:from[2])

" --- same-file jump: cursor on `local_helper` in main.cpp → line 14 ---
call cursor(1, 1)
call search('return \zslocal_helper', 'W')
call fakeide#goto#jump()
call Check('goto-samefile-buffer', fnamemodify(bufname('%'), ':p') ==# s:main,
      \ 'buf=' . bufname('%'))
call Check('goto-samefile-line', line('.') == 14,
      \ 'lnum=' . line('.'))
call fakeide#goto#back()

" --- exact match: clang filter is prefix; ensure we don't accept prefixes ---
" 'compute' as a symbol does NOT exist; the filter would still match
" `compute_sum`, but our pick_decl requires name == sym → no AST hit →
" vimgrep fallback (or no jump). Either way, we must NOT silently jump.
call cursor(1, 1)
" Probe pick_decl directly via the symbol-lookup pipeline: temporarily insert a
" line containing the bare token `compute` so <cword> resolves to it, then
" jump. We expect either (a) no movement (no fallback hit) or (b) quickfix
" opened by the fallback — never a silent jump to compute_sum's decl.
call append(line('$'), '// probe: compute here.')
call cursor(line('$'), 1)
call search('\<compute\>', 'cW')
let s:beforeline = line('.')
let s:beforebuf  = bufnr('%')
call fakeide#goto#jump()
let s:no_silent_jump = (bufnr('%') == s:beforebuf && line('.') == s:beforeline)
      \ || &buftype ==# 'quickfix'
call Check('goto-no-prefix-jump', s:no_silent_jump,
      \ 'buf=' . bufnr('%') . ' line=' . line('.') . ' bt=' . &buftype)
" Tidy up: close quickfix if it opened, then back to main and undo the probe.
if &buftype ==# 'quickfix' | cclose | endif
if fnamemodify(bufname('%'), ':p') !=# s:main
  execute 'buffer ' . fnameescape(s:main)
endif
silent undo

let s:out = empty($FAKEIDE_SMOKE_OUT) ? '/tmp/fakeide_goto.txt' : $FAKEIDE_SMOKE_OUT
call writefile(g:R, s:out)
qa!
