" plugin/fakeide.vim — fake-ide bootstrap: config, signs, user commands.
" Rules: docs/INSTRUCTIONS.md   Architecture: docs/DESIGN.md

if exists('g:loaded_fakeide')
  finish
endif
let g:loaded_fakeide = 1

if v:version < 800 || !has('job') || !has('channel')
  echohl WarningMsg
  echomsg 'fake-ide: requires Vim 8.0+ with +job and +channel — disabled'
  echohl None
  finish
endif

let s:save_cpo = &cpo
set cpo&vim

" --- Configuration (override in your vimrc) ---
let g:fakeide_c_std       = get(g:, 'fakeide_c_std', 'c11')
let g:fakeide_cpp_std     = get(g:, 'fakeide_cpp_std', 'c++17')
let g:fakeide_extra_flags = get(g:, 'fakeide_extra_flags', [])
let g:fakeide_compiler    = get(g:, 'fakeide_compiler', 'clang')

" Tier 2 — completion. omnifunc (i_CTRL-X_CTRL-O) is on by default; auto-firing
" the popup after . -> :: is opt-in because the omnifunc is synchronous and
" briefly blocks while clang parses (see autoload/fakeide/complete.vim).
let g:fakeide_complete_auto    = get(g:, 'fakeide_complete_auto', 0)
let g:fakeide_complete_timeout = get(g:, 'fakeide_complete_timeout', 3000)
let g:fakeide_complete_max     = get(g:, 'fakeide_complete_max', 200)

" --- Diagnostic signs (used from Tier 1 onward) ---
if has('signs')
  sign define FakeIdeError   text=E> texthl=ErrorMsg
  sign define FakeIdeWarning text=W> texthl=WarningMsg
endif

" --- User commands ---
command! FakeIdeReloadFlags call fakeide#flags#reload() | echo 'fake-ide: flags cache cleared'
command! FakeIdeFlags       echo fakeide#flags#for(expand('%:p'))
command! FakeIdeStatus      call s:status()
command! FakeIdeCheck       call fakeide#diag#check()
command! FakeIdeClear       call fakeide#diag#clear()
command! FakeIdeComplete    call feedkeys("i\<C-x>\<C-o>", 'n')

function! s:status() abort
  let l:flags = fakeide#flags#for(expand('%:p'))
  echo 'fake-ide  vim=' . v:version . '  compiler=' . g:fakeide_compiler
  echo '  file:   ' . expand('%:t')
  echo '  source: ' . fakeide#flags#source()
  echo '  flags:  ' . join(l:flags, ' ')
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
