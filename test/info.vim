" test/info.vim — headless Tier 3 type-info test. Run via test/run.sh.
" Verifies: K mapping wired; the code-completion-based lookup finds the entry
" whose word == cword and renders its rebuilt signature. Must run in a pty so
" job/channel callbacks are pumped, AND because the lookup waits on a
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

" Capture what fakeide#info#show() echoes (1-line, no popups in 8.0).
function! CaptureInfo() abort
  redir => l:out
  silent call fakeide#info#show()
  redir END
  return substitute(l:out, '\n', '', 'g')
endfunction

let s:main = s:root . '/test/fixtures/tier3/main.cpp'
execute 'edit ' . fnameescape(s:main)
setfiletype cpp
call fakeide#enable()

let s:map = maparg('K', 'n', 0, 1)
call Check('info-map-wired', !empty(s:map) && get(s:map, 'buffer', 0) == 1,
      \ 'map=' . string(s:map))

" --- member variable: w.width → int width ---
call cursor(1, 1)
call search('w\.\zswidth\>', 'W')
let s:line = CaptureInfo()
call Check('info-width-rettype', s:line =~# 'int',
      \ 'echo=' . s:line)
call Check('info-width-name', s:line =~# 'width',
      \ 'echo=' . s:line)

" --- member function: w.area() → int area() const ---
call cursor(1, 1)
call search('w\.\zsarea\>', 'W')
let s:line = CaptureInfo()
call Check('info-area-rettype', s:line =~# 'int',
      \ 'echo=' . s:line)
call Check('info-area-signature',
      \ s:line =~# 'area' && s:line =~# '(' && s:line =~# 'const',
      \ 'echo=' . s:line)

" --- cross-file function declared in lib.h: compute_sum(int,int) → int ---
call cursor(1, 1)
call search('\<compute_sum\>', 'W')
let s:line = CaptureInfo()
call Check('info-compute-sum-rettype', s:line =~# 'int',
      \ 'echo=' . s:line)
call Check('info-compute-sum-params',
      \ s:line =~# 'int .*int',
      \ 'echo=' . s:line)

let s:out = empty($FAKEIDE_SMOKE_OUT) ? '/tmp/fakeide_info.txt' : $FAKEIDE_SMOKE_OUT
call writefile(g:R, s:out)
qa!
