" autoload/fakeide/diag.vim — Tier 1 diagnostics engine.
"
" Runs the compiler async via job.vim, parses its output, and surfaces
" errors/warnings as gutter signs + a location list, with the message under the
" cursor echoed on the command line (our 8.0 "hover" substitute).
" See docs/INSTRUCTIONS.md §3 and docs/DESIGN.md §5.3.
"
" Command (buffer fed on stdin so unsaved edits are reflected):
"   <compiler> -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
"              -x <c|c++> <flags from flags.vim> -I<file dir> -
"
" Why stdin (not the file on disk): live diagnostics must reflect what is on
" screen, not the last save. clang reports the unit as "<stdin>"; we map that
" back to the buffer. -I<file dir> keeps quoted #include resolution working
" (stdin has no directory of its own, so clang would otherwise use cwd).
"
" Why manual parsing (not getqflist({'lines',...})): that dict form is a later
" 8.0.x patch — not present in the pinned 8.0.0000 build (verified). We parse
" with matchlist() instead. Likewise signs use :sign place/unplace because
" sign_place() does not exist in this build and sign groups are 8.1+.
"
" Public API:
"   fakeide#diag#enable()    -> per-buffer wiring (autocmds, maps, first run).
"   fakeide#diag#check()     -> run diagnostics now for the current buffer.
"   fakeide#diag#schedule()  -> debounced run (idle / typing triggers).
"   fakeide#diag#clear()     -> remove signs + location list for the buffer.
"   fakeide#diag#echo()      -> echo the diagnostic under the cursor, if any.

if exists('g:loaded_fakeide_diag')
  finish
endif
let g:loaded_fakeide_diag = 1

let s:save_cpo = &cpo
set cpo&vim

" Monotonic sign-id allocator. 8.0 has no sign groups, so we track the ids we
" placed per buffer (b:fakeide_sign_ids) and unplace them by id on refresh.
" Base is set high to avoid colliding with signs other code may place.
let s:sign_seq = 9000

let s:warned_no_compiler = 0

function! s:enabled() abort
  return get(g:, 'fakeide_diag_enabled', 1)
endfunction

" --- triggers -------------------------------------------------------------

function! fakeide#diag#check() abort
  call s:run(bufnr('%'))
endfunction

function! fakeide#diag#schedule() abort
  if !s:enabled()
    return
  endif
  let l:bufnr = bufnr('%')
  let l:t = getbufvar(l:bufnr, 'fakeide_diag_timer', -1)
  if l:t != -1
    call timer_stop(l:t)
  endif
  let l:delay = get(g:, 'fakeide_diag_debounce', 300)
  call setbufvar(l:bufnr, 'fakeide_diag_timer',
        \ timer_start(l:delay, function('s:on_timer', [l:bufnr])))
endfunction

function! s:on_timer(bufnr, timer) abort
  call setbufvar(a:bufnr, 'fakeide_diag_timer', -1)
  call s:run(a:bufnr)
endfunction

" --- run ------------------------------------------------------------------

function! s:run(bufnr) abort
  if !s:enabled() || !bufexists(a:bufnr)
    return
  endif
  let l:compiler = exepath(get(g:, 'fakeide_compiler', 'clang'))
  if empty(l:compiler)
    if !s:warned_no_compiler
      let s:warned_no_compiler = 1
      echohl WarningMsg
      echomsg 'fake-ide: compiler not found: ' . get(g:, 'fakeide_compiler', 'clang')
      echohl None
    endif
    return
  endif
  let l:fname = fnamemodify(bufname(a:bufnr), ':p')
  let l:flags = fakeide#flags#for(l:fname)
  let l:lang  = getbufvar(a:bufnr, '&filetype') ==# 'cpp' ? 'c++' : 'c'
  let l:dir   = fnamemodify(l:fname, ':h')
  let l:cmd = [l:compiler, '-fsyntax-only', '-fno-color-diagnostics',
        \ '-fno-caret-diagnostics', '-x', l:lang]
        \ + l:flags + ['-I' . l:dir, '-']
  call fakeide#job#run(l:cmd, {
        \ 'tag':     'diag:' . a:bufnr,
        \ 'stdin':   getbufline(a:bufnr, 1, '$'),
        \ 'timeout': get(g:, 'fakeide_diag_timeout', 10000),
        \ 'on_done': function('s:on_done', [a:bufnr]),
        \ })
endfunction

function! s:on_done(bufnr, result) abort
  if !bufexists(a:bufnr)
    return
  endif
  call s:apply(a:bufnr, s:parse(a:result.out + a:result.err, a:bufnr))
endfunction

" --- parse ----------------------------------------------------------------

" Turn raw clang/gcc lines into location-list items. Diagnostics for the main
" unit come back as "<stdin>:line:col:" → mapped to a:bufnr; anything else
" (errors inside included headers) keeps its real filename.
function! s:parse(lines, bufnr) abort
  let l:items = []
  for l:line in a:lines
    let l:m = matchlist(l:line,
          \ '\v^(.{-}):(\d+):(\d+):\s+(fatal error|error|warning|note):\s+(.*)$')
    if empty(l:m)
      continue
    endif
    let l:sev  = l:m[4]
    let l:type = l:sev =~# 'error' ? 'E' : (l:sev ==# 'warning' ? 'W' : 'I')
    let l:main = l:m[1] ==# '<stdin>' || l:m[1] ==# '-'
    let l:item = {
          \ 'lnum': str2nr(l:m[2]),
          \ 'col':  str2nr(l:m[3]),
          \ 'type': l:type,
          \ 'text': l:m[5],
          \ 'main': l:main,
          \ }
    if l:main
      let l:item.bufnr = a:bufnr
    else
      let l:item.filename = l:m[1]
    endif
    call add(l:items, l:item)
  endfor
  return l:items
endfunction

" --- apply (signs + loclist + echo cache) --------------------------------

function! s:apply(bufnr, items) abort
  call s:clear_signs(a:bufnr)

  " Worst severity per line (main unit only) → one sign per line.
  let l:sign_for = {}
  let l:byline = {}
  for l:it in a:items
    if !get(l:it, 'main', 0)
      continue
    endif
    let l:byline[l:it.lnum] = get(l:byline, l:it.lnum, [])
    call add(l:byline[l:it.lnum], l:it)
    if l:it.type ==# 'E'
      let l:sign_for[l:it.lnum] = 'E'
    elseif l:it.type ==# 'W' && get(l:sign_for, l:it.lnum, '') !=# 'E'
      let l:sign_for[l:it.lnum] = 'W'
    endif
  endfor

  let l:ids = []
  for l:lnum in keys(l:sign_for)
    let l:id = s:sign_seq
    let s:sign_seq += 1
    let l:name = l:sign_for[l:lnum] ==# 'E' ? 'FakeIdeError' : 'FakeIdeWarning'
    execute printf('sign place %d line=%s name=%s buffer=%d',
          \ l:id, l:lnum, l:name, a:bufnr)
    call add(l:ids, l:id)
  endfor

  call setbufvar(a:bufnr, 'fakeide_sign_ids', l:ids)
  call setbufvar(a:bufnr, 'fakeide_diags', l:byline)

  " Location list lives per-window; set it on a window showing this buffer.
  let l:winnr = bufwinnr(a:bufnr)
  if l:winnr > 0
    call setloclist(l:winnr, a:items, 'r')
  endif
endfunction

function! s:clear_signs(bufnr) abort
  for l:id in getbufvar(a:bufnr, 'fakeide_sign_ids', [])
    execute 'sign unplace ' . l:id . ' buffer=' . a:bufnr
  endfor
  call setbufvar(a:bufnr, 'fakeide_sign_ids', [])
endfunction

function! fakeide#diag#clear() abort
  let l:bufnr = bufnr('%')
  call s:clear_signs(l:bufnr)
  call setbufvar(l:bufnr, 'fakeide_diags', {})
  let l:winnr = bufwinnr(l:bufnr)
  if l:winnr > 0
    call setloclist(l:winnr, [], 'r')
  endif
endfunction

" --- echo (our 8.0 hover substitute) --------------------------------------

function! fakeide#diag#echo() abort
  let l:diags = get(b:, 'fakeide_diags', {})
  let l:lnum = line('.')
  if !has_key(l:diags, l:lnum)
    return
  endif
  let l:it = l:diags[l:lnum][0]
  let l:label = l:it.type ==# 'E' ? 'E' : (l:it.type ==# 'W' ? 'W' : 'note')
  let l:msg = '[' . l:label . '] ' . l:it.text
  let l:max = &columns - 12
  if l:max > 0 && len(l:msg) > l:max
    let l:msg = strpart(l:msg, 0, l:max - 3) . '...'
  endif
  echo l:msg
endfunction

" --- per-buffer wiring ----------------------------------------------------

function! fakeide#diag#enable() abort
  if !s:enabled()
    return
  endif
  let l:b = bufnr('%')
  augroup fakeide_diag
    execute 'autocmd! * <buffer=' . l:b . '>'
    execute 'autocmd BufWritePost <buffer=' . l:b . '> call fakeide#diag#check()'
    if get(g:, 'fakeide_diag_on_idle', 1)
      execute 'autocmd CursorHold <buffer=' . l:b . '> call fakeide#diag#schedule()'
    endif
    if get(g:, 'fakeide_diag_on_insert', 0)
      execute 'autocmd TextChangedI <buffer=' . l:b . '> call fakeide#diag#schedule()'
    endif
    execute 'autocmd CursorMoved,CursorHold <buffer=' . l:b . '> call fakeide#diag#echo()'
  augroup END

  if get(g:, 'fakeide_diag_maps', 1)
    nnoremap <silent> <buffer> ]d :lnext<CR>
    nnoremap <silent> <buffer> [d :lprev<CR>
  endif

  call fakeide#diag#check()
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
