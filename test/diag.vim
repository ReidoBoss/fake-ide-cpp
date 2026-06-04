" test/diag.vim — headless Tier 1 diagnostics test. Run via test/run.sh.
" Verifies: clang -fsyntax-only round-trip, parse → loclist (E + W) with the
" main unit mapped to the buffer, gutter signs placed, cursor echo, and that
" UNSAVED buffer edits are reflected (the stdin design). Must run in a pty so
" job/channel callbacks are pumped (see test/run.sh).
" Writes PASS/FAIL lines to $FAKEIDE_SMOKE_OUT (or a /tmp default).

set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
runtime plugin/fakeide.vim

let g:R = []
function! Check(name, cond, detail) abort
  call add(g:R, (a:cond ? 'PASS ' : 'FAIL ') . a:name . '  | ' . a:detail)
endfunction

" Wait until the current window's location list is non-empty (async settled).
function! WaitLoc(max_ticks) abort
  let l:w = 0
  while empty(getloclist(0)) && l:w < a:max_ticks
    sleep 10m
    let l:w += 1
  endwhile
  return l:w * 10
endfunction

let s:file = s:root . '/test/fixtures/tier1/broken.c'
execute 'edit ' . fnameescape(s:file)
setfiletype c

" --- flags: -Wall is picked up from the tier1 .fakeide ---
let s:flags = fakeide#flags#for(s:file)
call Check('flags-wall', index(s:flags, '-Wall') >= 0, string(s:flags))

" --- run diagnostics on the saved file ---
call fakeide#enable()
let s:ms = WaitLoc(1500)
let s:loc = getloclist(0)
call Check('diag-loclist-populated', !empty(s:loc), 'items=' . len(s:loc) . ' waited=' . s:ms . 'ms')

let s:types = map(copy(s:loc), 'v:val.type')
call Check('diag-has-error',   index(s:types, 'E') >= 0, 'types=' . string(s:types))
call Check('diag-has-warning', index(s:types, 'W') >= 0, 'types=' . string(s:types))

" main-unit diagnostics are mapped back to THIS buffer (not a "<stdin>" buffer)
let s:err = filter(copy(s:loc), 'v:val.type ==# "E"')
call Check('diag-error-bufnr',
      \ !empty(s:err) && s:err[0].bufnr == bufnr('%'),
      \ 'bufnr=' . (empty(s:err) ? '?' : s:err[0].bufnr) . ' cur=' . bufnr('%'))
call Check('diag-error-line',
      \ !empty(s:err) && s:err[0].lnum == 8,
      \ 'lnum=' . (empty(s:err) ? '?' : s:err[0].lnum))

" --- gutter signs placed (one per diagnostic line) ---
call Check('diag-signs-placed',
      \ len(get(b:, 'fakeide_sign_ids', [])) >= 2,
      \ 'ids=' . string(get(b:, 'fakeide_sign_ids', [])))
redir => s:signdump
silent execute 'sign place buffer=' . bufnr('%')
redir END
call Check('diag-sign-error-defined',
      \ s:signdump =~# 'FakeIdeError', 'dump=' . substitute(s:signdump, '\n', '|', 'g'))
call Check('diag-sign-warning-defined',
      \ s:signdump =~# 'FakeIdeWarning', 'dump=' . substitute(s:signdump, '\n', '|', 'g'))

" --- cursor echo on the error line returns a non-empty message ---
call cursor(8, 1)
let s:echo = ''
redir => s:echo
silent call fakeide#diag#echo()
redir END
call Check('diag-echo-nonempty', s:echo =~# 'undeclared', 'echo=' . substitute(s:echo, '\n', '', 'g'))

" --- UNSAVED edits are reflected (the whole point of feeding stdin) ---
" Add a brand-new error line in memory only; do NOT write the file.
call append(line('$'), 'int trailing(void) { return nope_unsaved; }')
let s:newline = line('$')
call setloclist(0, [], 'r')               " clear so WaitLoc detects the refresh
call fakeide#diag#check()
let s:ms2 = WaitLoc(1500)
let s:loc2 = getloclist(0)
let s:unsaved_hit = !empty(filter(copy(s:loc2),
      \ 'v:val.type ==# "E" && v:val.lnum == ' . s:newline))
call Check('diag-unsaved-reflected', s:unsaved_hit,
      \ 'looking for E@' . s:newline . ' in ' . string(map(copy(s:loc2), '[v:val.type, v:val.lnum]')))

" --- clear removes signs + loclist ---
call fakeide#diag#clear()
call Check('diag-clear-signs', empty(get(b:, 'fakeide_sign_ids', [])), 'ids=' . string(get(b:, 'fakeide_sign_ids', [])))
call Check('diag-clear-loclist', empty(getloclist(0)), 'items=' . len(getloclist(0)))

let s:out = empty($FAKEIDE_SMOKE_OUT) ? '/tmp/fakeide_diag.txt' : $FAKEIDE_SMOKE_OUT
call writefile(g:R, s:out)
qa!
