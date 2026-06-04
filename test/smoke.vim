" test/smoke.vim — headless Tier 0 smoke test. Run via test/run.sh.
" Verifies: plugin loads, flags resolution (.fakeide + defaults), async job round-trip.
" Writes PASS/FAIL lines to the file named in $FAKEIDE_SMOKE_OUT (or /tmp default).

set nocompatible
let s:root = expand('<sfile>:p:h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
runtime plugin/fakeide.vim

let g:R = []
function! Check(name, cond, detail) abort
  call add(g:R, (a:cond ? 'PASS ' : 'FAIL ') . a:name . '  | ' . a:detail)
endfunction

" --- features the design depends on ---
call Check('features', has('job') && has('channel') && has('timers') && has('signs'),
      \ 'job=' . has('job') . ' channel=' . has('channel') . ' timers=' . has('timers') . ' signs=' . has('signs'))

" --- flags: .fakeide path ---
let s:cfile = s:root . '/test/fixtures/hello.c'
let s:f1 = fakeide#flags#for(s:cfile)
call Check('flags-fakeide-source', fakeide#flags#source() ==# '.fakeide', 'source=' . fakeide#flags#source())
call Check('flags-fakeide-std', index(s:f1, '-std=c11') >= 0, string(s:f1))

" --- flags: defaults path (a path with no markers above it) ---
let s:f2 = fakeide#flags#for('/tmp/fakeide_no_markers_xyz/thing.cpp')
call Check('flags-defaults-source', fakeide#flags#source() ==# 'defaults', 'source=' . fakeide#flags#source())
call Check('flags-defaults-cppstd', index(s:f2, '-std=c++17') >= 0, string(s:f2))

" --- async job round-trip ---
let g:done = 0
let g:res = {}
function! OnDone(r) abort
  let g:done = 1
  let g:res = a:r
endfunction
call fakeide#job#run(['/bin/echo', 'hello-from-job'], {'on_done': function('OnDone'), 'timeout': 5000})
let s:waited = 0
while !g:done && s:waited < 300
  sleep 10m
  let s:waited += 1
endwhile
call Check('job-completed', g:done, 'done=' . g:done . ' waited=' . (s:waited * 10) . 'ms')
call Check('job-exit-code', get(g:res, 'code', -1) == 0, 'code=' . get(g:res, 'code', -1))
call Check('job-stdout', get(g:res, 'out', []) == ['hello-from-job'], 'out=' . string(get(g:res, 'out', [])))

" --- stdin round-trip (the mechanism Tier 2 completion relies on) ---
let g:done2 = 0
let g:res2 = {}
function! OnDone2(r) abort
  let g:done2 = 1
  let g:res2 = a:r
endfunction
call fakeide#job#run(['/bin/cat'], {'stdin': ['alpha', 'beta'], 'on_done': function('OnDone2'), 'timeout': 5000})
let s:w2 = 0
while !g:done2 && s:w2 < 300
  sleep 10m
  let s:w2 += 1
endwhile
call Check('job-stdin', get(g:res2, 'out', []) == ['alpha', 'beta'], 'out=' . string(get(g:res2, 'out', [])))

" --- stderr-only capture (regression guard) ---
" A process that writes ONLY to stderr (empty stdout) must not lose its output.
" job.vim merges stderr into stdout by default, so it arrives in result.out.
" This is exactly clang -fsyntax-only's shape (diagnostics on stderr) — Tier 1
" saw zero diagnostics until this was fixed. See docs/DESIGN.md §5.2.
let g:done_e = 0
let g:res_e = {}
function! OnDoneE(r) abort
  let g:done_e = 1
  let g:res_e = a:r
endfunction
call fakeide#job#run(['/bin/sh', '-c', 'echo only-stderr 1>&2'],
      \ {'on_done': function('OnDoneE'), 'timeout': 5000})
let s:we = 0
while !g:done_e && s:we < 300
  sleep 10m
  let s:we += 1
endwhile
call Check('job-stderr-captured',
      \ index(get(g:res_e, 'out', []) + get(g:res_e, 'err', []), 'only-stderr') >= 0,
      \ 'out=' . string(get(g:res_e, 'out', [])) . ' err=' . string(get(g:res_e, 'err', [])))

" --- real clang invocation on the valid fixture (Tier 1 foundation) ---
let g:done3 = 0
let g:res3 = {}
function! OnDone3(r) abort
  let g:done3 = 1
  let g:res3 = a:r
endfunction
let s:clang = exepath('clang')
if !empty(s:clang)
  call fakeide#job#run([s:clang, '-fsyntax-only'] + s:f1 + [s:cfile],
        \ {'on_done': function('OnDone3'), 'timeout': 15000})
  let s:w3 = 0
  while !g:done3 && s:w3 < 1500
    sleep 10m
    let s:w3 += 1
  endwhile
  call Check('clang-syntax-ok', g:done3 && get(g:res3, 'code', -1) == 0,
        \ 'code=' . get(g:res3, 'code', '?') . ' err=' . string(get(g:res3, 'err', [])))
else
  call Check('clang-syntax-ok', 0, 'clang not found on PATH')
endif

let s:out = empty($FAKEIDE_SMOKE_OUT) ? '/tmp/fakeide_smoke.txt' : $FAKEIDE_SMOKE_OUT
call writefile(g:R, s:out)
qa!
