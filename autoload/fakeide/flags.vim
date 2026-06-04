" autoload/fakeide/flags.vim — resolve compile flags for a source file.
"
" Correct flags (-I, -std, -D) are the #1 determinant of completion/diagnostic
" quality, so this is the foundation. Resolution order (see docs/DESIGN.md §5.1):
"   1. compile_commands.json  (clang/cmake's own output — not a third party)
"   2. .fakeide               (our simple flat flags file)
"   3. built-in defaults
"
" Public API:
"   fakeide#flags#for(file)  -> List of flag strings for that file.
"   fakeide#flags#reload()   -> clear caches (after editing flags/json).
"   fakeide#flags#source()   -> which source produced the last result.

if exists('g:loaded_fakeide_flags')
  finish
endif
let g:loaded_fakeide_flags = 1

let s:save_cpo = &cpo
set cpo&vim

let s:flags_cache  = {}   " absolute file path -> List of flags
let s:ccjson_cache = {}   " json path -> {mtime, entries: {file -> flags}}
let s:last_source  = 'n/a'

function! fakeide#flags#reload() abort
  let s:flags_cache  = {}
  let s:ccjson_cache = {}
endfunction

function! fakeide#flags#source() abort
  return s:last_source
endfunction

" Walk up from a:start_dir (inclusive) looking for any marker name (file or dir).
" Returns the containing directory, or '' if none found up to the fs root.
function! s:find_up(start_dir, names) abort
  let l:dir = a:start_dir
  while 1
    for l:name in a:names
      let l:p = l:dir . '/' . l:name
      if filereadable(l:p) || isdirectory(l:p)
        return l:dir
      endif
    endfor
    let l:parent = fnamemodify(l:dir, ':h')
    if l:parent ==# l:dir
      return ''
    endif
    let l:dir = l:parent
  endwhile
endfunction

function! s:is_c(file) abort
  let l:ext = tolower(fnamemodify(a:file, ':e'))
  return l:ext ==# 'c' || l:ext ==# 'h'
endfunction

" Resolve a possibly-relative path against a base dir, returning an absolute one.
function! s:absolute(path, base) abort
  if a:path =~# '^/'
    return simplify(a:path)
  endif
  if empty(a:base)
    return simplify(fnamemodify(a:path, ':p'))
  endif
  return simplify(a:base . '/' . a:path)
endfunction

function! s:defaults(file) abort
  let l:std = s:is_c(a:file)
        \ ? '-std=' . get(g:, 'fakeide_c_std', 'c11')
        \ : '-std=' . get(g:, 'fakeide_cpp_std', 'c++17')
  let l:flags = [l:std, '-I' . fnamemodify(a:file, ':p:h')]
  return l:flags + get(g:, 'fakeide_extra_flags', [])
endfunction

function! s:read_fakeide(path) abort
  let l:flags = []
  for l:line in readfile(a:path)
    let l:line = substitute(l:line, '#.*$', '', '')      " strip comments
    let l:line = substitute(l:line, '^\s\+\|\s\+$', '', 'g')
    if !empty(l:line)
      call extend(l:flags, split(l:line))
    endif
  endfor
  return l:flags
endfunction

" Pull only parse-relevant flags out of a compile_commands.json command line,
" dropping the compiler, -c, -o <out>, dependency flags, and the source file.
" Include/define paths are made absolute against the entry's directory.
function! s:filter_args(args, dir) abort
  let l:keep = []
  let l:n = len(a:args)
  let l:i = (l:n > 0 && a:args[0] !~# '^-') ? 1 : 0   " skip compiler token
  let l:withpath = ['-isystem', '-iquote', '-idirafter', '-include', '-isysroot', '-F']
  while l:i < l:n
    let l:a = a:args[l:i]
    if l:a =~# '^-std='
      call add(l:keep, l:a)
    elseif l:a =~# '^-I'
      if l:a ==# '-I' && l:i + 1 < l:n
        let l:i += 1
        call add(l:keep, '-I' . s:absolute(a:args[l:i], a:dir))
      else
        call add(l:keep, '-I' . s:absolute(strpart(l:a, 2), a:dir))
      endif
    elseif l:a =~# '^-\(D\|U\)'
      call add(l:keep, l:a)
      if l:a =~# '^-\(D\|U\)$' && l:i + 1 < l:n
        let l:i += 1
        call add(l:keep, a:args[l:i])
      endif
    elseif index(l:withpath, l:a) >= 0
      call add(l:keep, l:a)
      if l:i + 1 < l:n
        let l:i += 1
        call add(l:keep, l:a ==# '-include' ? a:args[l:i] : s:absolute(a:args[l:i], a:dir))
      endif
    elseif l:a =~# '^-\(nostdinc\|pthread\|fblocks\|fno-\|fmodules\)'
      call add(l:keep, l:a)
    endif
    let l:i += 1
  endwhile
  return l:keep
endfunction

function! s:entry_args(item) abort
  if has_key(a:item, 'arguments') && type(a:item.arguments) == type([])
    return copy(a:item.arguments)
  elseif has_key(a:item, 'command')
    return split(a:item.command)   " NOTE: naive split; quoted args w/ spaces unsupported (Tier 0)
  endif
  return []
endfunction

function! s:ccjson_entries(path) abort
  let l:mtime = getftime(a:path)
  if has_key(s:ccjson_cache, a:path) && s:ccjson_cache[a:path].mtime == l:mtime
    return s:ccjson_cache[a:path].entries
  endif
  let l:entries = {}
  try
    let l:db = json_decode(join(readfile(a:path), "\n"))
  catch
    let l:db = v:null
  endtry
  if type(l:db) == type([])
    for l:item in l:db
      if type(l:item) != type({}) || !has_key(l:item, 'file')
        continue
      endif
      let l:dir  = get(l:item, 'directory', '')
      let l:file = s:absolute(l:item.file, l:dir)
      let l:entries[l:file] = s:filter_args(s:entry_args(l:item), l:dir)
    endfor
  endif
  let s:ccjson_cache[a:path] = {'mtime': l:mtime, 'entries': l:entries}
  return l:entries
endfunction

function! fakeide#flags#for(file) abort
  let l:file = simplify(fnamemodify(a:file, ':p'))
  if has_key(s:flags_cache, l:file)
    let s:last_source = get(s:flags_cache, l:file . "\x01src", 'cache')
    return s:flags_cache[l:file]
  endif
  let l:dir = fnamemodify(l:file, ':h')
  let l:flags = []
  let l:source = 'defaults'

  " 1. compile_commands.json
  let l:root = s:find_up(l:dir, ['compile_commands.json'])
  if !empty(l:root)
    let l:entries = s:ccjson_entries(l:root . '/compile_commands.json')
    if has_key(l:entries, l:file)
      let l:flags = l:entries[l:file]
      let l:source = 'compile_commands.json'
    endif
  endif

  " 2. .fakeide
  if empty(l:flags)
    let l:froot = s:find_up(l:dir, ['.fakeide'])
    if !empty(l:froot)
      let l:flags = s:read_fakeide(l:froot . '/.fakeide')
      let l:source = '.fakeide'
    endif
  endif

  " 3. defaults
  if empty(l:flags)
    let l:flags = s:defaults(l:file)
    let l:source = 'defaults'
  endif

  let s:flags_cache[l:file] = l:flags
  let s:flags_cache[l:file . "\x01src"] = l:source
  let s:last_source = l:source
  return l:flags
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
