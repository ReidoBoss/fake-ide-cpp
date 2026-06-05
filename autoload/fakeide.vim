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

" --- shared grep helpers (used by goto.vim + refs.vim so they can't drift) ---
"
" Walk up from the source file's directory looking for a project marker
" (compile_commands.json / .fakeide / .git). Returns the containing dir or ''.
" The same heuristic flags.vim uses for resolving compile_commands.json, kept
" here so refs/goto can run independently of any flag resolution call.
function! fakeide#project_root(from_file) abort
  let l:dir = fnamemodify(a:from_file, ':h')
  while !empty(l:dir)
    for l:marker in ['compile_commands.json', '.fakeide', '.git']
      if filereadable(l:dir . '/' . l:marker) || isdirectory(l:dir . '/' . l:marker)
        return l:dir
      endif
    endfor
    let l:parent = fnamemodify(l:dir, ':h')
    if l:parent ==# l:dir | break | endif
    let l:dir = l:parent
  endwhile
  return ''
endfunction

" Build the list of `:vimgrep` globs for the gcc/no-clang code paths (goto's
" smart-jump fallback + refs#find). Honors:
"   g:fakeide_goto_grep_exts : list of bare extensions, default the full
"                              C/C++ set.
"   g:fakeide_grep_scope     : 'root' (default) walks up to a project marker
"                              and recurses with `**/*.ext`; 'samedir' restricts
"                              to the buffer's own directory and does NOT
"                              recurse. Useful for flat layouts where every
"                              source / header lives in one directory.
function! fakeide#grep_globs(from_file) abort
  let l:exts = get(g:, 'fakeide_goto_grep_exts',
        \ ['c', 'h', 'cc', 'hh', 'cpp', 'hpp', 'cxx', 'hxx'])
  let l:scope = get(g:, 'fakeide_grep_scope', 'root')
  if l:scope ==# 'samedir'
    let l:dir = fnamemodify(a:from_file, ':h')
    let l:globs = []
    for l:e in l:exts
      call add(l:globs, fnameescape(l:dir) . '/*.' . l:e)
    endfor
    return l:globs
  endif
  " 'root' (default): walk up to a project marker, then recurse.
  let l:root = fakeide#project_root(a:from_file)
  if empty(l:root) | let l:root = fnamemodify(a:from_file, ':h') | endif
  let l:globs = []
  for l:e in l:exts
    call add(l:globs, fnameescape(l:root) . '/**/*.' . l:e)
  endfor
  return l:globs
endfunction

" Run a project grep for the identifier `sym` and populate the quickfix
" list. Used by goto's smart-jump vimgrep fallback and by refs#find. Returns
" 1 if any hits were found, 0 otherwise. The caller inspects getqflist().
"
" Strategy:
"   * If `grep` is on PATH and g:fakeide_use_external_grep is non-zero
"     (default 1), shell out to `grep -nwIE` via :grep! — much faster than
"     :vimgrep, which loads each candidate file into Vim's buffer parser to
"     scan it. The pty/buffer overhead becomes the bottleneck on large trees.
"   * Otherwise fall back to :vimgrep over the same glob set so behaviour is
"     identical, just slower.
"
" Honors g:fakeide_grep_scope ('root' default | 'samedir') and
" g:fakeide_goto_grep_exts (default the full C/C++ extension set).
function! fakeide#grep(sym, from_file) abort
  if get(g:, 'fakeide_use_external_grep', 1) && executable('grep')
    return s:grep_external(a:sym, a:from_file)
  endif
  return s:grep_vim(a:sym, a:from_file)
endfunction

" External-grep backend.
"   samedir : explicit file list via glob() (no -r recursion).
"   root    : grep -r with --include filters from a project marker.
function! s:grep_external(sym, from_file) abort
  let l:scope = get(g:, 'fakeide_grep_scope', 'root')
  let l:exts  = get(g:, 'fakeide_goto_grep_exts',
        \ ['c', 'h', 'cc', 'hh', 'cpp', 'hpp', 'cxx', 'hxx'])
  let l:saved_prg = &grepprg
  let l:saved_fmt = &grepformat
  " `grep -nwIE`: -n line numbers, -w whole-word match (so `foo` doesn't match
  " `foobar`), -I skip binary files, -E extended regex (cheap, future-proof).
  let &grepprg    = 'grep -nwIE'
  let &grepformat = '%f:%l:%m'

  let l:patt = shellescape(a:sym)
  let l:args = ''

  if l:scope ==# 'samedir'
    let l:dir = fnamemodify(a:from_file, ':h')
    let l:files = []
    for l:e in l:exts
      call extend(l:files, glob(l:dir . '/*.' . l:e, 1, 1))
    endfor
    if empty(l:files)
      call setqflist([], 'r')
      let &grepprg = l:saved_prg | let &grepformat = l:saved_fmt
      return 0
    endif
    let l:args = l:patt . ' ' . join(map(copy(l:files), 'shellescape(v:val)'), ' ')
  else
    " 'root': walk up to a project marker, recurse with --include filters.
    let l:root = fakeide#project_root(a:from_file)
    if empty(l:root) | let l:root = fnamemodify(a:from_file, ':h') | endif
    let l:includes = ''
    for l:e in l:exts
      let l:includes .= ' --include=' . shellescape('*.' . l:e)
    endfor
    let l:args = '-r' . l:includes . ' ' . l:patt . ' ' . shellescape(l:root)
  endif

  try
    silent! execute 'grep! ' . l:args
  catch
  endtry
  let &grepprg = l:saved_prg | let &grepformat = l:saved_fmt
  return !empty(getqflist())
endfunction

" :vimgrep backend — used when external grep isn't available (no `grep` on
" PATH, or user opted out via g:fakeide_use_external_grep=0).
function! s:grep_vim(sym, from_file) abort
  let l:globs = fakeide#grep_globs(a:from_file)
  let l:pattern = '\<' . a:sym . '\>'
  try
    execute 'silent vimgrep /' . l:pattern . '/jg ' . join(l:globs, ' ')
  catch /^Vim\%((\a\+)\)\=:E480/
    return 0
  catch
    return 0
  endtry
  return !empty(getqflist())
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
