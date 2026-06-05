" autoload/fakeide/goto.vim — Tier 3 go-to-definition.
"
" Primary path: drive `clang -Xclang -ast-dump=json` filtered to the symbol
" under the cursor, parse the JSON, jump to the Decl node's loc (file/line/col).
" Buffer is fed on stdin (same design as Tier 1/2) so unsaved edits are visible.
" Fallback: `vimgrep` for `\<symbol\>` across the project, presented in quickfix.
" See docs/INSTRUCTIONS.md §3 and docs/DESIGN.md §5.5.
"
" Command (buffer on stdin so unsaved edits are reflected):
"   clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
"         -Xclang -ast-dump=json -Xclang -ast-dump-filter=<symbol> \
"         -x <c|c++> <flags from flags.vim> -I<file dir> -
"
" Output shape (probed against Apple clang 17):
"   * The filter is a PREFIX match, so we must verify `name == symbol` ourselves.
"   * clang emits a STREAM of top-level JSON objects (no array wrapper). Each
"     starts with `{` at column 0 and ends with `}` at column 0; we split on
"     that boundary and json_decode() each object independently.
"   * Each top-level object's `loc` has `file` ("<stdin>" or absolute path),
"     `line`, `col`. Implicit decls (compiler builtins matched by prefix) have
"     `loc: {}` — skipped. `includedFrom` is informational; the location we
"     want is `loc.file`/`loc.line`/`loc.col` on the matched Decl itself.
"
" BLOCKING NOTE: like Tier 2 completion, the jump runs clang synchronously
" (via job.vim + bounded :sleep-poll), because a jump is a one-shot user action
" — see DESIGN.md §5.4 / §10. The wait is capped by g:fakeide_goto_timeout.
"
" 8.0.0000 caveat: settagstack()/gettagstack() are 8.0.1453+, NOT present here.
" We keep our own script-local position stack so :FakeIdeBack works without
" leaning on the tag stack API.
"
" Public API:
"   fakeide#goto#enable()   -> per-buffer wiring (mappings).
"   fakeide#goto#jump()     -> jump to the definition of the word under cursor.
"   fakeide#goto#back()     -> pop the position stack (un-jump).

if exists('g:loaded_fakeide_goto')
  finish
endif
let g:loaded_fakeide_goto = 1

let s:save_cpo = &cpo
set cpo&vim

let s:warned_no_compiler = 0

" Our own jump stack: list of {bufnr, lnum, col, file}.
let s:tagstack = []

" Single sync slot (one jump in flight at a time — it blocks the UI).
let s:sync = {'done': 1, 'out': []}

function! s:enabled() abort
  return get(g:, 'fakeide_goto_enabled', 1)
endfunction

function! s:compiler() abort
  let l:compiler = exepath(get(g:, 'fakeide_compiler', 'clang'))
  if empty(l:compiler) && !s:warned_no_compiler
    let s:warned_no_compiler = 1
    echohl WarningMsg
    echomsg 'fake-ide: compiler not found: ' . get(g:, 'fakeide_compiler', 'clang')
    echohl None
  endif
  return l:compiler
endfunction

" --- public jump ----------------------------------------------------------

function! fakeide#goto#jump() abort
  if !s:enabled()
    return
  endif
  let l:sym = expand('<cword>')
  if empty(l:sym) || l:sym !~# '^[A-Za-z_][A-Za-z0-9_]*$'
    echohl WarningMsg | echo 'fake-ide: no symbol under cursor' | echohl None
    return
  endif

  let l:bufnr = bufnr('%')
  let l:from  = {'bufnr': l:bufnr, 'lnum': line('.'), 'col': col('.'),
        \ 'file': fnamemodify(bufname(l:bufnr), ':p')}

  let l:target = s:resolve_via_ast(l:sym, l:bufnr)
  if empty(l:target)
    " Fallback: project-wide vimgrep into the quickfix list.
    return s:vimgrep_fallback(l:sym, l:from)
  endif

  call add(s:tagstack, l:from)
  call s:jump_to(l:target)
endfunction

function! fakeide#goto#back() abort
  if empty(s:tagstack)
    echohl WarningMsg | echo 'fake-ide: jump stack empty' | echohl None
    return
  endif
  let l:prev = remove(s:tagstack, -1)
  if bufexists(l:prev.bufnr) && bufnr(l:prev.bufnr) > 0
    execute 'buffer ' . l:prev.bufnr
  elseif !empty(l:prev.file) && filereadable(l:prev.file)
    execute 'edit ' . fnameescape(l:prev.file)
  endif
  call cursor(l:prev.lnum, l:prev.col)
endfunction

" --- AST primary ----------------------------------------------------------

function! s:resolve_via_ast(sym, bufnr) abort
  let l:compiler = s:compiler()
  if empty(l:compiler)
    return {}
  endif
  let l:fname = fnamemodify(bufname(a:bufnr), ':p')
  let l:flags = fakeide#flags#for(l:fname)
  let l:lang  = getbufvar(a:bufnr, '&filetype') ==# 'cpp' ? 'c++' : 'c'
  let l:dir   = fnamemodify(l:fname, ':h')
  let l:cmd = [l:compiler, '-fsyntax-only', '-fno-color-diagnostics',
        \ '-fno-caret-diagnostics',
        \ '-Xclang', '-ast-dump=json',
        \ '-Xclang', '-ast-dump-filter=' . a:sym,
        \ '-x', l:lang]
        \ + l:flags + ['-I' . l:dir, '-']

  let l:lines = s:run_sync(l:cmd, getbufline(a:bufnr, 1, '$'), a:bufnr)
  return s:pick_decl(l:lines, a:sym, l:fname)
endfunction

" Split the stream of top-level JSON objects (each starts with '{' at col 0,
" ends with '}' at col 0), json_decode each, and return the first matching
" Decl whose name == sym and whose loc has an explicit line. Same-file matches
" win over cross-file; first match wins within that.
function! s:pick_decl(lines, sym, cur_file) abort
  let l:objs = s:split_objects(a:lines)
  let l:best_same = {}
  let l:best_any  = {}
  for l:obj in l:objs
    let l:json = s:safe_decode(l:obj)
    if type(l:json) != type({}) | continue | endif
    if get(l:json, 'name', '') !=# a:sym | continue | endif
    if get(l:json, 'kind', '') !~# 'Decl$' | continue | endif
    let l:loc = get(l:json, 'loc', {})
    if type(l:loc) != type({}) || !has_key(l:loc, 'line') | continue | endif
    let l:file = get(l:loc, 'file', '')
    if l:file ==# '<stdin>' || l:file ==# '-'
      let l:file = a:cur_file
    endif
    if empty(l:file) | continue | endif
    let l:hit = {'file': l:file,
          \ 'lnum': get(l:loc, 'line', 1),
          \ 'col':  get(l:loc, 'col', 1),
          \ 'kind': get(l:json, 'kind', '')}
    if l:file ==# a:cur_file && empty(l:best_same)
      let l:best_same = l:hit
    elseif empty(l:best_any)
      let l:best_any = l:hit
    endif
  endfor
  return !empty(l:best_same) ? l:best_same : l:best_any
endfunction

" Split a:lines into a list of JSON object strings. Top-level boundaries are
" lines that are exactly '{' or '}' (clang pretty-prints with column-0 braces).
function! s:split_objects(lines) abort
  let l:objs = []
  let l:cur = []
  let l:in = 0
  for l:line in a:lines
    if !l:in && l:line ==# '{'
      let l:in = 1
      let l:cur = ['{']
    elseif l:in
      call add(l:cur, l:line)
      if l:line ==# '}'
        call add(l:objs, join(l:cur, "\n"))
        let l:in = 0
        let l:cur = []
      endif
    endif
  endfor
  return l:objs
endfunction

function! s:safe_decode(s) abort
  try
    return json_decode(a:s)
  catch
    return v:null
  endtry
endfunction

" --- jump -----------------------------------------------------------------

function! s:jump_to(target) abort
  let l:cur = fnamemodify(bufname('%'), ':p')
  if a:target.file !=# l:cur
    if !filereadable(a:target.file)
      echohl WarningMsg | echo 'fake-ide: cannot read ' . a:target.file | echohl None
      return
    endif
    execute 'edit ' . fnameescape(a:target.file)
  endif
  call cursor(a:target.lnum, a:target.col)
  normal! zz
endfunction

" --- vimgrep fallback -----------------------------------------------------
"
" Used when the AST primary returns nothing (clang failed, or the symbol is
" outside the TU). Heuristic and dumb: search the project for `\<sym\>` in
" C/C++ source extensions and present matches in the quickfix list. The user
" picks the right one. We push to our stack so :FakeIdeBack still works.

function! s:vimgrep_fallback(sym, from) abort
  let l:root = s:project_root(a:from.file)
  if empty(l:root) | let l:root = fnamemodify(a:from.file, ':h') | endif
  let l:exts = get(g:, 'fakeide_goto_grep_exts', ['c','h','cc','hh','cpp','hpp','cxx','hxx'])
  let l:globs = []
  for l:e in l:exts
    call add(l:globs, fnameescape(l:root) . '/**/*.' . l:e)
  endfor
  let l:pattern = '\<' . a:sym . '\>'
  try
    execute 'silent vimgrep /' . l:pattern . '/j ' . join(l:globs, ' ')
  catch /^Vim\%((\a\+)\)\=:E480/
    " No matches.
    echohl WarningMsg | echo 'fake-ide: no definition or matches for ' . a:sym | echohl None
    return
  catch
    echohl WarningMsg | echo 'fake-ide: vimgrep fallback failed: ' . v:exception | echohl None
    return
  endtry
  let l:qf = getqflist()
  if empty(l:qf)
    echohl WarningMsg | echo 'fake-ide: no matches for ' . a:sym | echohl None
    return
  endif
  call add(s:tagstack, a:from)
  copen
  echo 'fake-ide: AST jump unavailable — ' . len(l:qf) . ' grep matches for ' . a:sym
endfunction

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

" --- synchronous wait over the async job wrapper --------------------------
" Mirrors the pattern in complete.vim: queue an async run, then :sleep-poll the
" event loop (which pumps channel callbacks) until on_done fires or we cap out.

function! s:run_sync(cmd, lines, bufnr) abort
  let l:timeout = get(g:, 'fakeide_goto_timeout', 5000)
  let s:sync = {'done': 0, 'out': []}
  call fakeide#job#run(a:cmd, {
        \ 'tag':     'goto:' . a:bufnr,
        \ 'stdin':   a:lines,
        \ 'timeout': l:timeout,
        \ 'on_done': function('s:on_sync'),
        \ })
  let l:waited = 0
  let l:ceiling = l:timeout + 500
  while !s:sync.done && l:waited < l:ceiling
    sleep 10m
    let l:waited += 10
  endwhile
  return s:sync.done ? s:sync.out : []
endfunction

function! s:on_sync(result) abort
  let s:sync.out  = a:result.out
  let s:sync.done = 1
endfunction

" --- per-buffer wiring ----------------------------------------------------

function! fakeide#goto#enable() abort
  if !s:enabled()
    return
  endif
  if get(g:, 'fakeide_goto_maps', 1)
    nnoremap <silent> <buffer> <C-]> :call fakeide#goto#jump()<CR>
    nnoremap <silent> <buffer> <C-t> :call fakeide#goto#back()<CR>
  endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
