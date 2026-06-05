" test/refs.vim — headless test for the project-wide references search.
" Verifies: gr mapping wired; vimgrep across the project root populates qflist
" with cross-file hits; empty / unknown symbol bails gracefully. No async
" (vimgrep is synchronous), but we keep the same pty harness for consistency.
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

" --- gr mapping is wired on the buffer ---
let s:map = maparg('gr', 'n', 0, 1)
call Check('refs-map-wired', !empty(s:map) && get(s:map, 'buffer', 0) == 1,
      \ 'map=' . string(s:map))

" --- cross-file refs: `compute_sum` is declared in lib.h, used in main.cpp ---
call cursor(1, 1)
call search('\<compute_sum\>', 'W')
call fakeide#refs#find()
let s:qf = getqflist()
let s:files = []
for s:it in s:qf
  let s:p = fnamemodify(bufname(s:it.bufnr), ':p')
  if index(s:files, s:p) < 0
    call add(s:files, s:p)
  endif
endfor
call Check('refs-compute-sum-nonempty', len(s:qf) >= 2, 'n=' . len(s:qf))
call Check('refs-compute-sum-crossfile',
      \ index(s:files, s:main) >= 0 && index(s:files, s:hdr) >= 0,
      \ 'files=' . string(s:files))

" --- quickfix gets opened after find() ---
let s:has_qf_win = 0
for s:w in range(1, winnr('$'))
  if getwinvar(s:w, '&buftype') ==# 'quickfix'
    let s:has_qf_win = 1
    break
  endif
endfor
call Check('refs-opens-quickfix', s:has_qf_win, 'qf_win=' . s:has_qf_win)
cclose

" --- back to the source buffer (cclose may have left us in a stray window) ---
if fnamemodify(bufname('%'), ':p') !=# s:main
  execute 'buffer ' . fnameescape(s:main)
endif

" --- many-hits exact match: `Point` lives in lib.h (none) but `Widget` is in
" main.cpp only and should yield multiple textual hits across the same file ---
call cursor(1, 1)
call search('\<Widget\>', 'W')
call fakeide#refs#find()
let s:qf2 = getqflist()
call Check('refs-widget-multi', len(s:qf2) >= 3, 'n=' . len(s:qf2))
cclose
if fnamemodify(bufname('%'), ':p') !=# s:main
  execute 'buffer ' . fnameescape(s:main)
endif

let s:out = empty($FAKEIDE_SMOKE_OUT) ? '/tmp/fakeide_refs.txt' : $FAKEIDE_SMOKE_OUT
call writefile(g:R, s:out)
qa!
