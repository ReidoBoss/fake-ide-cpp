" autoload/fakeide/info.vim — Tier 3 type / signature info.
"
" Reuses the Tier 2 completion mechanism: aim `clang -code-completion-at` at the
" START of the identifier under the cursor so clang returns completions whose
" typed prefix IS the full identifier. We then find the entry whose `word`
" equals the cword and echo its reconstructed signature (and return type).
" Buffer is fed on stdin so unsaved edits are reflected. See DESIGN.md §5.6.
"
" Output (Vim 8.0 has no popups): command-line echo by default, or :pedit a
" scratch preview window when g:fakeide_info_in_preview is set.
"
" Public API:
"   fakeide#info#enable()  -> per-buffer wiring (K mapping).
"   fakeide#info#show()    -> show info for the word under the cursor.

if exists('g:loaded_fakeide_info')
  finish
endif
let g:loaded_fakeide_info = 1

let s:save_cpo = &cpo
set cpo&vim

let s:warned_no_compiler = 0
let s:warned_no_clang    = 0
let s:sync = {'done': 1, 'out': []}

function! s:enabled() abort
  return get(g:, 'fakeide_info_enabled', 1)
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

" --- public show ----------------------------------------------------------

function! fakeide#info#show() abort
  if !s:enabled() | return | endif
  let l:sym = expand('<cword>')
  if empty(l:sym) || l:sym !~# '^[A-Za-z_][A-Za-z0-9_]*$'
    echohl WarningMsg | echo 'fake-ide: no symbol under cursor' | echohl None
    return
  endif

  " Type info reuses clang's code-completion machinery — gcc has no equivalent.
  if !fakeide#has_clang()
    if !s:warned_no_clang
      let s:warned_no_clang = 1
      echohl WarningMsg
      echomsg 'fake-ide: type info requires clang (gcc has no -code-completion-at); disabled'
      echohl None
    endif
    return
  endif

  let l:compiler = s:compiler()
  if empty(l:compiler) | return | endif

  let l:bufnr = bufnr('%')
  let l:fname = fnamemodify(bufname(l:bufnr), ':p')
  let l:flags = fakeide#flags#for(l:fname)
  let l:lang  = &filetype ==# 'cpp' ? 'c++' : 'c'
  let l:dir   = fnamemodify(l:fname, ':h')

  " Aim clang at the start of the identifier so the typed prefix is the full
  " cword; matching candidates therefore include an exact-word match.
  let l:line  = getline('.')
  let l:start = col('.') - 1
  while l:start > 0 && l:line[l:start - 1] =~# '\k'
    let l:start -= 1
  endwhile
  let l:lnum = line('.')
  let l:cnum = l:start + 1
  let l:at   = printf('-code-completion-at=-:%d:%d', l:lnum, l:cnum)
  let l:cmd  = [l:compiler, '-fsyntax-only', '-fno-color-diagnostics',
        \ '-fno-caret-diagnostics', '-x', l:lang, '-Xclang', l:at]
        \ + l:flags + ['-I' . l:dir, '-']

  let l:out = s:run_sync(l:cmd, getbufline(l:bufnr, 1, '$'), l:bufnr)
  let l:match = s:find_match(l:out, l:sym)
  if empty(l:match)
    echohl WarningMsg | echo 'fake-ide: no info for ' . l:sym | echohl None
    return
  endif
  call s:render(l:sym, l:match)
endfunction

" --- parse: pull the first COMPLETION line whose name equals the symbol ---
"
" Same `COMPLETION: <name> : [#ret#]<sig>` shape as complete.vim §parse,
" minus the candidate-list machinery (we only need ONE matching entry).

function! s:find_match(lines, sym) abort
  for l:line in a:lines
    if l:line !~# '^COMPLETION: '
      continue
    endif
    let l:rest = strpart(l:line, len('COMPLETION: '))
    let l:sep  = match(l:rest, ' : ')
    let l:name = l:sep >= 0 ? strpart(l:rest, 0, l:sep) : l:rest
    let l:sig  = l:sep >= 0 ? strpart(l:rest, l:sep + 3) : ''
    " Drop the access qualifier (we still want to MATCH on the bare name).
    let l:q = matchlist(l:name, '\v^(.*) \(([^)]+)\)$')
    if !empty(l:q)
      if l:q[2] =~? 'inaccessible\|hidden\|not accessible'
        continue
      endif
      let l:name = l:q[1]
    endif
    " Strip template/paren tail, keep `operator…` whole — mirrors complete.vim.
    let l:word = l:name =~# '^operator' ? l:name
          \ : matchstr(l:name, '^[^([:space:]<]\+')
    if l:word !=# a:sym
      continue
    endif
    return s:format(l:sig)
  endfor
  return {}
endfunction

" Turn a raw signature string into {ret, sig}. Same unwrapping as complete.vim's
" s:item — kept local so info.vim doesn't reach into complete.vim's script scope.
function! s:format(sig) abort
  if empty(a:sig)
    return {'ret': '', 'sig': ''}
  endif
  let l:ret = ''
  let l:rest = a:sig
  let l:m = matchlist(l:rest, '^\[#\(.\{-}\)#\]')
  if !empty(l:m)
    let l:ret = l:m[1]
    let l:rest = strpart(l:rest, len(l:m[0]))
  endif
  let l:rest = substitute(l:rest, '<#\(.\{-}\)#>', '\1', 'g')
  let l:rest = substitute(l:rest, '{#\(.\{-}\)#}', '\1', 'g')
  let l:rest = substitute(l:rest, '\[#\(.\{-}\)#\]', '\1', 'g')
  return {'ret': l:ret, 'sig': l:rest}
endfunction

" --- render: echo (default) or preview window ----------------------------

function! s:render(sym, m) abort
  let l:line = empty(a:m.ret) ? a:m.sig
        \ : (empty(a:m.sig) ? a:m.ret : (a:m.ret . ' ' . a:m.sig))
  if empty(l:line) | let l:line = a:sym | endif
  if get(g:, 'fakeide_info_in_preview', 0)
    call s:show_preview(a:sym, l:line)
    return
  endif
  " Truncate to one command line (8.0 has no floats / popups — §5.6).
  let l:max = &columns - 12
  if l:max > 0 && len(l:line) > l:max
    let l:line = strpart(l:line, 0, l:max - 3) . '...'
  endif
  echo l:line
endfunction

function! s:show_preview(sym, line) abort
  let l:tmp = tempname() . '.fakeide-info'
  call writefile([a:sym . ':', a:line], l:tmp)
  execute 'silent pedit ' . fnameescape(l:tmp)
  " Mark the preview buffer as scratch so :wq isn't required to leave it.
  let l:winnr = 0
  for l:w in range(1, winnr('$'))
    if getwinvar(l:w, '&previewwindow')
      let l:winnr = l:w
      break
    endif
  endfor
  if l:winnr > 0
    call setbufvar(winbufnr(l:winnr), '&buftype', 'nofile')
    call setbufvar(winbufnr(l:winnr), '&bufhidden', 'wipe')
    call setbufvar(winbufnr(l:winnr), '&swapfile', 0)
  endif
endfunction

" --- synchronous wait over the async job wrapper --------------------------
" Same pattern as complete.vim / goto.vim — info is on-demand, so blocking
" briefly is acceptable; never autorun on CursorHold for that reason.

function! s:run_sync(cmd, lines, bufnr) abort
  let l:timeout = get(g:, 'fakeide_info_timeout', 3000)
  let s:sync = {'done': 0, 'out': []}
  call fakeide#job#run(a:cmd, {
        \ 'tag':     'info:' . a:bufnr,
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

function! fakeide#info#enable() abort
  if !s:enabled() | return | endif
  if get(g:, 'fakeide_info_maps', 1)
    nnoremap <silent> <buffer> K :call fakeide#info#show()<CR>
  endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
