" autoload/fakeide.vim — per-buffer setup entry point for C/C++ buffers.
" Called from ftplugin/{c,cpp}.vim. Tier 1+ will extend this to wire diagnostics
" autocommands, set omnifunc, and add mappings. For Tier 0 it just marks the
" buffer active and validates that flag resolution works.

if exists('g:loaded_fakeide_core')
  finish
endif
let g:loaded_fakeide_core = 1

function! fakeide#enable() abort
  if get(b:, 'fakeide_active', 0)
    return
  endif
  let b:fakeide_active = 1
  " Resolve flags once so they are cached and ready for later tiers.
  call fakeide#flags#for(expand('%:p'))
endfunction
