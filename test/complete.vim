" test/complete.vim — headless Tier 2 completion test. Run via test/run.sh.
" Verifies: the two-call omnifunc contract (findstart byte index + candidate
" dicts), clang -code-completion-at round-trip parsed into word/menu/info/kind,
" partial-prefix filtering, and that UNSAVED buffer edits are reflected (the
" stdin design). Must run in a pty so job/channel callbacks are pumped, AND
" because the omnifunc waits on a sleep-poll loop (see test/run.sh).
" Writes PASS/FAIL lines to $FAKEIDE_SMOKE_OUT (or a /tmp default).

set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
runtime plugin/fakeide.vim

let g:R = []
function! Check(name, cond, detail) abort
  call add(g:R, (a:cond ? 'PASS ' : 'FAIL ') . a:name . '  | ' . a:detail)
endfunction

" Run the full two-call omnifunc at the cursor's current position.
" Returns [findstart, base, items].
function! Complete() abort
  let l:start = fakeide#complete#omni(1, '')
  let l:base  = l:start < 0 ? '' : strpart(getline('.'), l:start, col('.') - 1 - l:start)
  let l:items = fakeide#complete#omni(0, l:base)
  return [l:start, l:base, l:items]
endfunction

function! Words(items) abort
  return map(copy(a:items), 'v:val.word')
endfunction

let s:file = s:root . '/test/fixtures/tier2/sample.cpp'
execute 'edit ' . fnameescape(s:file)
setfiletype cpp
call fakeide#enable()

" --- omnifunc is wired on the buffer ---
call Check('omnifunc-set', &omnifunc ==# 'fakeide#complete#omni', 'omnifunc=' . &omnifunc)

" --- member completion at `p.` (cursor on the 'x' just after the dot) ---
call cursor(1, 1)
call search('p\.\zsx', 'W')
let [s:start, s:base, s:items] = Complete()
let s:words = Words(s:items)
call Check('member-nonempty', !empty(s:items),
      \ 'n=' . len(s:items) . ' base=' . string(s:base) . ' words=' . string(s:words[0 : 9]))
call Check('member-has-x',    index(s:words, 'x') >= 0,    'words=' . string(s:words[0 : 9]))
call Check('member-has-y',    index(s:words, 'y') >= 0,    'words=' . string(s:words[0 : 9]))
call Check('member-has-dist', index(s:words, 'dist') >= 0, 'words=' . string(s:words[0 : 9]))
call Check('member-has-move', index(s:words, 'move') >= 0, 'words=' . string(s:words[0 : 9]))

" findstart points just after the dot (base is empty here).
call Check('member-base-empty', s:base ==# '', 'base=' . string(s:base) . ' start=' . s:start)

" --- rich item fields: return type (menu), kind, signature (info) ---
function! Find(items, word) abort
  for l:it in a:items
    if l:it.word ==# a:word
      return l:it
    endif
  endfor
  return {}
endfunction
let s:dist = Find(s:items, 'dist')
call Check('dist-kind-func', get(s:dist, 'kind', '') ==# 'f', 'dist=' . string(s:dist))
call Check('dist-menu-rettype', get(s:dist, 'menu', '') ==# 'double', 'dist=' . string(s:dist))
let s:x = Find(s:items, 'x')
call Check('x-kind-var',  get(s:x, 'kind', '') ==# 'v',   'x=' . string(s:x))
call Check('x-menu-int',  get(s:x, 'menu', '') ==# 'int', 'x=' . string(s:x))
let s:move = Find(s:items, 'move')
call Check('move-info-has-params', get(s:move, 'info', '') =~# 'int dx', 'move=' . string(s:move))

" --- partial prefix `p.di` filters to dist (clang-side filtering) ---
call cursor(1, 1)
call search('p\.di\zs;', 'W')
let [s:pstart, s:pbase, s:pitems] = Complete()
let s:pwords = Words(s:pitems)
call Check('partial-base-di', s:pbase ==# 'di', 'base=' . string(s:pbase))
call Check('partial-has-dist', index(s:pwords, 'dist') >= 0, 'words=' . string(s:pwords))
call Check('partial-excludes-x', index(s:pwords, 'x') < 0, 'words=' . string(s:pwords))

" --- UNSAVED edits reflected: add a member in memory only, do NOT save ---
" Insert a new field after line 4 (`int y;`); everything below shifts down.
call append(4, '  int unsaved_member;')
call cursor(1, 1)
call search('p\.\zsx', 'W')
let [s:ustart, s:ubase, s:uitems] = Complete()
let s:uwords = Words(s:uitems)
call Check('unsaved-reflected', index(s:uwords, 'unsaved_member') >= 0,
      \ 'words=' . string(s:uwords[0 : 9]))

let s:out = empty($FAKEIDE_SMOKE_OUT) ? '/tmp/fakeide_complete.txt' : $FAKEIDE_SMOKE_OUT
call writefile(g:R, s:out)
qa!
