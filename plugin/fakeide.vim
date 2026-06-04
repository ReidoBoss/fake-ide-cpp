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

" --- Diagnostic signs (used from Tier 1 onward) ---
if has('signs')
  sign define FakeIdeError   text=E> texthl=ErrorMsg
  sign define FakeIdeWarning text=W> texthl=WarningMsg
endif

" --- User commands ---
command! FakeIdeReloadFlags call fakeide#flags#reload() | echo 'fake-ide: flags cache cleared'
command! FakeIdeFlags       echo fakeide#flags#for(expand('%:p'))
command! FakeIdeStatus      call s:status()

function! s:status() abort
  let l:flags = fakeide#flags#for(expand('%:p'))
  echo 'fake-ide  vim=' . v:version . '  compiler=' . g:fakeide_compiler
  echo '  file:   ' . expand('%:t')
  echo '  source: ' . fakeide#flags#source()
  echo '  flags:  ' . join(l:flags, ' ')
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
