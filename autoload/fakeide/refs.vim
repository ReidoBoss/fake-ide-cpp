" autoload/fakeide/refs.vim — find references (textual, vimgrep-based).
"
" The cheap counterpart to Tier 3's clang-driven goto. We don't parse the TU;
" we just `vimgrep /\<sym\>/j` across C/C++ files under the project root and
" present the hits in the quickfix list. Fast, dumb, and good enough for "show
" me where this is used" when the user doesn't need scope-aware accuracy.
"
" Honest limits (documented in DESIGN.md §5.7):
"   * Textual match. Catches comments, strings, and same-named locals in
"     unrelated scopes.
"   * No type / scope filtering. `dist` inside two unrelated classes is one
"     bucket of hits, not two.
"   * Doesn't dedupe overload sets, doesn't skip declarations vs uses.
"
" Anything finer needs the full clang AST walk (`-ast-dump=json` no filter,
" then traverse `DeclRefExpr` nodes by `referencedDecl.id`). That's a real
" chunk of work and is out of scope here — left as a future "Tier 4 / polish"
" task in PROGRESS.md.
"
" Public API:
"   fakeide#refs#enable()  -> per-buffer wiring (gr mapping).
"   fakeide#refs#find()    -> find references for the word under the cursor.

if exists('g:loaded_fakeide_refs')
  finish
endif
let g:loaded_fakeide_refs = 1

let s:save_cpo = &cpo
set cpo&vim

function! s:enabled() abort
  return get(g:, 'fakeide_refs_enabled', 1)
endfunction

" Reuse goto.vim's project-root heuristic semantics (compile_commands.json /
" .fakeide / .git markers, falling back to the buffer's directory). Kept local
" so refs.vim doesn't reach into goto.vim's script scope.
function! s:project_root(from_file) abort
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

function! fakeide#refs#find() abort
  if !s:enabled()
    return
  endif
  let l:sym = expand('<cword>')
  if empty(l:sym) || l:sym !~# '^[A-Za-z_][A-Za-z0-9_]*$'
    echohl WarningMsg | echo 'fake-ide: no symbol under cursor' | echohl None
    return
  endif

  let l:from = fnamemodify(bufname('%'), ':p')
  let l:root = s:project_root(l:from)
  if empty(l:root) | let l:root = fnamemodify(l:from, ':h') | endif

  " Same extension list as goto.vim's fallback so the two stay consistent.
  let l:exts = get(g:, 'fakeide_goto_grep_exts',
        \ ['c', 'h', 'cc', 'hh', 'cpp', 'hpp', 'cxx', 'hxx'])
  let l:globs = []
  for l:e in l:exts
    call add(l:globs, fnameescape(l:root) . '/**/*.' . l:e)
  endfor

  let l:pattern = '\<' . l:sym . '\>'
  try
    execute 'silent vimgrep /' . l:pattern . '/jg ' . join(l:globs, ' ')
  catch /^Vim\%((\a\+)\)\=:E480/
    echohl WarningMsg | echo 'fake-ide: no references to ' . l:sym | echohl None
    return
  catch
    echohl WarningMsg | echo 'fake-ide: refs search failed: ' . v:exception | echohl None
    return
  endtry

  let l:qf = getqflist()
  if empty(l:qf)
    echohl WarningMsg | echo 'fake-ide: no references to ' . l:sym | echohl None
    return
  endif
  copen
  echo printf('fake-ide: %d reference(s) to %s', len(l:qf), l:sym)
endfunction

function! fakeide#refs#enable() abort
  if !s:enabled()
    return
  endif
  if get(g:, 'fakeide_refs_maps', 1)
    nnoremap <silent> <buffer> gr :call fakeide#refs#find()<CR>
  endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
