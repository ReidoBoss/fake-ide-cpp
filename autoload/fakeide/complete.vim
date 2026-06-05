" autoload/fakeide/complete.vim — Tier 2 semantic completion engine.
"
" Drives `clang -Xclang -code-completion-at=-:LINE:COL -` over the CURRENT
" (unsaved) buffer fed on stdin, parses the `COMPLETION:` lines, and serves them
" through Vim's two-call omnifunc contract so they appear in the native
" insert-mode popup menu. See docs/INSTRUCTIONS.md §3 and docs/DESIGN.md §5.4.
"
" Command (buffer on stdin so unsaved edits are reflected):
"   clang -fsyntax-only -fno-color-diagnostics -fno-caret-diagnostics \
"         -x <c|c++> -Xclang -code-completion-at=-:L:C <flags> -I<dir> -
"
" We point clang at the CURSOR column (the end of the partial word), so clang
" itself filters candidates by what's already typed — essential for huge
" contexts like `std::` that would otherwise dump thousands of entries.
" `findstart` returns the start of the partial word, so Vim replaces just the
" typed prefix with the chosen candidate.
"
" BLOCKING NOTE (deliberate, documented — see DESIGN.md §5.4 / §10):
" Vim 8.0's omnifunc/completefunc contract is SYNCHRONOUS — the function must
" RETURN the candidate list. Vim 8.0 has no non-blocking completion API short of
" the `complete()` re-trigger hack (which flickers). So while we still run clang
" through the async job wrapper (job.vim — superseding stale jobs), the omnifunc
" then waits on a bounded `sleep`-poll loop that pumps channel callbacks. This
" briefly blocks the UI for the parse duration (the documented "no daemon" cost),
" but ONLY on an explicit completion request, never on every keystroke. The wait
" is capped by g:fakeide_complete_timeout. (`:sleep` is a Vim point where channel
" callbacks fire, so this works for real `i_CTRL-X_CTRL-O` too.)
"
" Public API:
"   fakeide#complete#omni(findstart, base) -> the omnifunc (set omnifunc=...).
"   fakeide#complete#enable()              -> per-buffer wiring (omnifunc + maps).
"   fakeide#complete#trigger(char)         -> <expr> helper for auto-trigger maps.

if exists('g:loaded_fakeide_complete')
  finish
endif
let g:loaded_fakeide_complete = 1

let s:save_cpo = &cpo
set cpo&vim

let s:warned_no_compiler = 0
let s:warned_no_clang    = 0

" Single sync slot: completion blocks, so only one run is ever in flight.
let s:sync = {'done': 1, 'out': []}

" Completion position captured during the findstart call. Vim's two omnifunc
" calls must point clang at the SAME spot, so we snapshot [line, col] when
" findstart runs (cursor at the end of the typed text) and reuse it for the
" candidates call rather than re-reading col('.') — which Vim may have moved.
let s:pos = [0, 0]

function! s:enabled() abort
  return get(g:, 'fakeide_complete_enabled', 1)
endfunction

" --- omnifunc (two-call contract) -----------------------------------------

function! fakeide#complete#omni(findstart, base) abort
  if a:findstart
    return s:findstart()
  endif
  return s:candidates()
endfunction

" First call: byte index (0-based) where the partial word begins. Scan back over
" keyword chars from the cursor. -2 cancels completion silently (e.g. no clang).
function! s:findstart() abort
  if !s:enabled() || empty(s:compiler())
    return -2
  endif
  " `-Xclang -code-completion-at` is clang-only. Cancel silently with a
  " one-shot warning so gcc-only users know why <C-x><C-o> does nothing.
  if !fakeide#has_clang()
    if !s:warned_no_clang
      let s:warned_no_clang = 1
      echohl WarningMsg
      echomsg 'fake-ide: semantic completion requires clang (gcc has no -code-completion-at); disabled'
      echohl None
    endif
    return -2
  endif
  let l:line = getline('.')
  let l:start = col('.') - 1
  while l:start > 0 && l:line[l:start - 1] =~# '\k'
    let l:start -= 1
  endwhile
  " Snapshot where to point clang: the cursor (end of the typed text), now,
  " while Vim still has it here. Reused by the candidates call.
  let s:pos = [line('.'), col('.')]
  return l:start
endfunction

" Second call: run clang at the cursor, parse, return completion dicts.
function! s:candidates() abort
  if !s:enabled()
    return []
  endif
  let l:compiler = s:compiler()
  if empty(l:compiler)
    return []
  endif
  let l:bufnr = bufnr('%')
  let l:fname = fnamemodify(bufname(l:bufnr), ':p')
  let l:flags = fakeide#flags#for(l:fname)
  let l:lang  = &filetype ==# 'cpp' ? 'c++' : 'c'
  let l:dir   = fnamemodify(l:fname, ':h')
  let l:lnum  = s:pos[0] > 0 ? s:pos[0] : line('.')
  let l:cnum  = s:pos[0] > 0 ? s:pos[1] : col('.')
  let l:at    = printf('-code-completion-at=-:%d:%d', l:lnum, l:cnum)
  let l:cmd = [l:compiler, '-fsyntax-only', '-fno-color-diagnostics',
        \ '-fno-caret-diagnostics', '-x', l:lang, '-Xclang', l:at]
        \ + l:flags + ['-I' . l:dir, '-']

  let l:out = s:run_sync(l:cmd, getline(1, '$'), l:bufnr)
  return s:parse(l:out)
endfunction

" --- synchronous wait over the async job wrapper --------------------------

function! s:run_sync(cmd, lines, bufnr) abort
  let l:timeout = get(g:, 'fakeide_complete_timeout', 3000)
  let s:sync = {'done': 0, 'out': []}
  call fakeide#job#run(a:cmd, {
        \ 'tag':     'complete:' . a:bufnr,
        \ 'stdin':   a:lines,
        \ 'timeout': l:timeout,
        \ 'on_done': function('s:on_sync'),
        \ })
  " Pump the event loop until the callback fires (or we give up). :sleep lets
  " Vim invoke channel/job callbacks. +500ms slack past the job's own timeout.
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

" --- parse clang COMPLETION: lines ----------------------------------------
"
" Two shapes (see DESIGN.md §5.4), verified against the company clang:
"   COMPLETION: <name> : [#<ret>#]<sig with <#params#>>[# const#]
"   COMPLETION: <name>                         (macro / keyword, no signature)
" Names may carry a qualifier we must honour:
"   COMPLETION: __padding (Inaccessible) : ...  -> skip
" Argument placeholders are `<#type name#>`; optional segments `{#...#}`.

function! s:parse(lines) abort
  let l:max  = get(g:, 'fakeide_complete_max', 200)
  let l:items = []
  let l:seen  = {}
  for l:line in a:lines
    if l:line !~# '^COMPLETION: '
      continue
    endif
    let l:rest = strpart(l:line, len('COMPLETION: '))

    " Split name from signature on the FIRST ' : ' (template args / operators
    " never contain it). No ' : ' means a bare macro/keyword candidate.
    let l:sep = match(l:rest, ' : ')
    if l:sep >= 0
      let l:name = strpart(l:rest, 0, l:sep)
      let l:sig  = strpart(l:rest, l:sep + 3)
    else
      let l:name = l:rest
      let l:sig  = ''
    endif

    " Drop an access qualifier like ' (Inaccessible)' / ' (Hidden)'.
    let l:q = matchlist(l:name, '\v^(.*) \(([^)]+)\)$')
    if !empty(l:q)
      if l:q[2] =~? 'inaccessible\|hidden\|not accessible'
        continue
      endif
      let l:name = l:q[1]
    endif

    let l:word = s:word_of(l:name)
    if empty(l:word)
      continue
    endif

    let l:item = s:item(l:word, l:sig)
    " Dedup identical word+menu (keep distinct overload signatures).
    let l:key = l:word . "\x01" . l:item.menu
    if has_key(l:seen, l:key)
      continue
    endif
    let l:seen[l:key] = 1
    call add(l:items, l:item)
    if len(l:items) >= l:max
      break
    endif
  endfor
  return l:items
endfunction

" The insertable identifier from a completion name. Keep operator names whole;
" otherwise cut at the first '<' (template args), '(' or space.
function! s:word_of(name) abort
  if a:name =~# '^operator'
    return a:name
  endif
  return matchstr(a:name, '^[^([:space:]<]\+')
endfunction

" Build a Vim completion dict from a candidate name + raw signature string.
function! s:item(word, sig) abort
  if empty(a:sig)
    " Macro / keyword: no type info.
    return {'word': a:word, 'menu': '', 'info': '', 'kind': 'd', 'dup': 1}
  endif

  " Leading [#return type#].
  let l:ret = ''
  let l:rest = a:sig
  let l:m = matchlist(l:rest, '^\[#\(.\{-}\)#\]')
  if !empty(l:m)
    let l:ret = l:m[1]
    let l:rest = strpart(l:rest, len(l:m[0]))
  endif

  " <#param#> -> param ; {#opt#} -> opt ; trailing [# const#] -> const.
  let l:rest = substitute(l:rest, '<#\(.\{-}\)#>', '\1', 'g')
  let l:rest = substitute(l:rest, '{#\(.\{-}\)#}', '\1', 'g')
  let l:rest = substitute(l:rest, '\[#\(.\{-}\)#\]', '\1', 'g')

  let l:is_func = l:rest =~# '('
  if l:ret !=# '' && l:is_func
    let l:kind = 'f'
  elseif l:ret !=# ''
    let l:kind = 'v'
  else
    let l:kind = 't'
  endif

  let l:menu = l:ret
  let l:info = empty(l:ret) ? l:rest : (l:ret . ' ' . l:rest)
  return {'word': a:word, 'menu': l:menu, 'info': l:info, 'kind': l:kind, 'dup': 1}
endfunction

" --- helpers / wiring -----------------------------------------------------

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

" <expr> insert-mode map helper: insert a:char, then fire omni-completion when
" it completes a member/scope access (.  ->  ::). Returns the keys to feed.
function! fakeide#complete#trigger(char) abort
  let l:keys = a:char
  if pumvisible()
    return l:keys
  endif
  let l:col = col('.')
  let l:before = strpart(getline('.'), 0, l:col - 1)
  " Decide on the text as it will be AFTER a:char is inserted.
  let l:after = l:before . a:char
  if a:char ==# '.'
    " A real member access, not a float literal: char before the dot is ident.
    if l:before =~# '\k$'
      let l:keys .= "\<C-x>\<C-o>"
    endif
  elseif a:char ==# '>'
    if l:after =~# '->$'
      let l:keys .= "\<C-x>\<C-o>"
    endif
  elseif a:char ==# ':'
    if l:after =~# '::$'
      let l:keys .= "\<C-x>\<C-o>"
    endif
  endif
  return l:keys
endfunction

function! fakeide#complete#enable() abort
  if !s:enabled()
    return
  endif
  setlocal omnifunc=fakeide#complete#omni

  if get(g:, 'fakeide_complete_auto', 0)
    " Opt-in: auto-fire the popup after . -> :: . Each fires the (blocking)
    " omnifunc, so this is off by default (see the BLOCKING NOTE at top).
    inoremap <silent> <buffer> <expr> . fakeide#complete#trigger('.')
    inoremap <silent> <buffer> <expr> > fakeide#complete#trigger('>')
    inoremap <silent> <buffer> <expr> : fakeide#complete#trigger(':')
  endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
