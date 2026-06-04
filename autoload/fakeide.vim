" autoload/fakeide.vim — per-buffer setup entry point for C/C++ buffers.
" Called from ftplugin/{c,cpp}.vim. Marks the buffer active, resolves compile
" flags, wires up the diagnostics engine (Tier 1) and semantic completion
" (Tier 2 — sets omnifunc). Tier 3+ will add goto/info mappings.

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
  " Tier 1: diagnostics (signs + location list + cursor echo).
  call fakeide#diag#enable()
  " Tier 2: semantic completion (omnifunc → clang -code-completion-at).
  call fakeide#complete#enable()
endfunction
