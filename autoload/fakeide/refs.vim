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

function! fakeide#refs#find() abort
  if !s:enabled()
    return
  endif
  let l:sym = expand('<cword>')
  if empty(l:sym) || l:sym !~# '^[A-Za-z_][A-Za-z0-9_]*$'
    echohl WarningMsg | echo 'fake-ide: no symbol under cursor' | echohl None
    return
  endif

  " Shared grep helper — same globs as goto.vim's fallback. Honors
  " g:fakeide_grep_scope ('samedir' vs 'root') and g:fakeide_goto_grep_exts.
  let l:from  = fnamemodify(bufname('%'), ':p')
  let l:globs = fakeide#grep_globs(l:from)

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
