" autoload/fakeide.vim — per-buffer setup entry point for C/C++ buffers.
" Called from ftplugin/{c,cpp}.vim. Marks the buffer active, resolves compile
" flags, wires up the diagnostics engine (Tier 1), semantic completion (Tier 2
" — sets omnifunc), and go-to-definition + type info (Tier 3 — C-] / C-t / K).

if exists('g:loaded_fakeide_core')
  finish
endif
let g:loaded_fakeide_core = 1

" Cache for the clang-or-not probe. -1 = unknown, 0 = no, 1 = yes.
let s:has_clang = -1

" Returns 1 if the configured compiler is actually clang. Cached per session;
" overridable via g:fakeide_has_clang (set to 0 to force the gcc-only path,
" useful for tests and for users who have clang installed but want to
" exercise the degraded experience).
"
" Why a probe (not a name check): on macOS `/usr/bin/gcc` IS clang (the
" Apple toolchain ships clang under both names). We have to inspect
" `<compiler> --version` to know what we're really driving. Output contains
" the word "clang" for both upstream clang and Apple clang; gcc-the-GNU
" prints "gcc (GCC) ..." with no "clang".
"
" Used by complete.vim / goto.vim / info.vim to disable themselves when the
" toolchain only has GNU gcc: `-Xclang -code-completion-at` and
" `-Xclang -ast-dump=json` are clang-only flags. Tier 1 diagnostics
" (`-fsyntax-only`) and refs (vimgrep) work with either compiler.
function! fakeide#has_clang() abort
  if exists('g:fakeide_has_clang')
    return g:fakeide_has_clang
  endif
  if s:has_clang >= 0
    return s:has_clang
  endif
  let l:compiler = exepath(get(g:, 'fakeide_compiler', 'clang'))
  if empty(l:compiler)
    let s:has_clang = 0
    return 0
  endif
  let l:ver = system(shellescape(l:compiler) . ' --version 2>&1')
  let s:has_clang = (l:ver =~? 'clang') ? 1 : 0
  return s:has_clang
endfunction

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
  " Tier 3: go-to-definition (clang AST dump) + type info (code-completion).
  call fakeide#goto#enable()
  call fakeide#info#enable()
  " Tier 3 extra: cheap project-wide references (vimgrep into quickfix).
  call fakeide#refs#enable()
endfunction
