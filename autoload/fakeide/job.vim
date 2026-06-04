" autoload/fakeide/job.vim — async process wrapper over Vim 8.0 jobs/channels.
"
" Every external process (clang/gcc) MUST go through here; never call job_start
" from other modules. See docs/INSTRUCTIONS.md §3 and docs/DESIGN.md §5.2.
"
" Public API:
"   fakeide#job#run(cmd, opts) -> job
"     cmd  : List argv (preferred — no shell quoting) or String.
"     opts : dict, all keys optional:
"       tag     : string. A new run with the same tag KILLS the previous one
"                 (debounced typing -> only the latest matters).
"       stdin   : List of lines OR a String fed to the process's stdin.
"       on_done : Funcref(result). result = {code, out, err, tag}; out/err Lists.
"       timeout : ms. Kill the run if it exceeds this (0 = no timeout).
"       merge_stderr : default 1. Merge the process's stderr into stdout (all
"                 lines arrive in result.out; result.err stays empty). Set to 0
"                 to keep them separate (result.err populated via a second pipe).
"
" Why merge stderr by default: with two separate pipes, a process that writes
" ONLY to stderr (empty stdout) EOFs stdout instantly; close_cb then fires and
" we finalize before the stderr data is delivered, LOSING it. clang
" -fsyntax-only is exactly this case (diagnostics go to stderr, stdout is
" empty). Merging gives a single stream with no cross-part race. Verified on
" Vim 8.0: separate streams drop stderr-only output; merged does not.
"   fakeide#job#stop(tag)        -> cancel the run registered under tag.
"   fakeide#job#is_running(tag)  -> 0/1.
"
" Completion model: we finish on close_cb (channel drained = all output read),
" which is the reliable signal. exit_cb timing is unreliable in Vim, so the exit
" code comes from exit_cb when it has fired, otherwise from job_info().exitval
" once the process is reaped (polled briefly). See test/ for the evidence.

if exists('g:loaded_fakeide_job')
  finish
endif
let g:loaded_fakeide_job = 1

let s:save_cpo = &cpo
set cpo&vim

" tag -> run dict, for supersede/cancel. Untagged runs are not tracked here.
let s:active = {}

let s:POLL_MAX = 300   " * 10ms = 3s ceiling waiting for the process to be reaped

function! s:detach(run) abort
  if a:run.timer >= 0
    call timer_stop(a:run.timer)
    let a:run.timer = -1
  endif
  if a:run.poll >= 0
    call timer_stop(a:run.poll)
    let a:run.poll = -1
  endif
  if !empty(a:run.tag) && has_key(s:active, a:run.tag) && s:active[a:run.tag] is a:run
    call remove(s:active, a:run.tag)
  endif
endfunction

function! s:finalize(run) abort
  if a:run.finished
    return
  endif
  let a:run.finished = 1
  call s:detach(a:run)
  if a:run.canceled
    return
  endif
  if a:run.Callback isnot v:null
    call call(a:run.Callback, [{
          \ 'code': a:run.code,
          \ 'out':  a:run.out,
          \ 'err':  a:run.err,
          \ 'tag':  a:run.tag,
          \ }])
  endif
endfunction

" Try to complete: needs the channel drained (closed) and the process reaped.
function! s:try_finish(run) abort
  if !a:run.closed || a:run.finished
    return
  endif
  if a:run.exited
    call s:finalize(a:run)
    return
  endif
  " Output is drained but exit_cb hasn't fired (unreliable). Read the real exit
  " status from job_info once the process is dead; poll briefly if not yet.
  if a:run.job isnot v:null && job_status(a:run.job) ==# 'dead'
    let a:run.code = get(job_info(a:run.job), 'exitval', a:run.code)
    call s:finalize(a:run)
  elseif a:run.poll < 0
    let a:run.poll = timer_start(10, function('s:on_poll', [a:run]), {'repeat': -1})
  endif
endfunction

function! s:on_poll(run, timer) abort
  let a:run.polls += 1
  if a:run.exited || (a:run.job isnot v:null && job_status(a:run.job) ==# 'dead')
    if !a:run.exited
      let a:run.code = get(job_info(a:run.job), 'exitval', a:run.code)
    endif
    call s:finalize(a:run)
  elseif a:run.polls >= s:POLL_MAX
    call s:finalize(a:run)   " give up waiting for reap; deliver what we have
  endif
endfunction

function! s:on_out(run, ch, msg) abort
  call add(a:run.out, a:msg)
endfunction

function! s:on_err(run, ch, msg) abort
  call add(a:run.err, a:msg)
endfunction

function! s:on_exit(run, job, code) abort
  let a:run.code = a:code
  let a:run.exited = 1
  call s:try_finish(a:run)
endfunction

function! s:on_close(run, ch) abort
  let a:run.closed = 1
  call s:try_finish(a:run)
endfunction

function! s:on_timeout(run, timer) abort
  let a:run.timer = -1
  let a:run.canceled = 1
  if a:run.job isnot v:null && job_status(a:run.job) ==# 'run'
    call job_stop(a:run.job, 'kill')
  endif
  call s:finalize(a:run)
endfunction

function! fakeide#job#run(cmd, opts) abort
  if !has('job') || !has('channel')
    throw 'fake-ide: this Vim lacks +job/+channel'
  endif
  let l:tag = get(a:opts, 'tag', '')

  " Supersede any in-flight run sharing this tag.
  if !empty(l:tag) && has_key(s:active, l:tag)
    call fakeide#job#stop(l:tag)
  endif

  let l:run = {
        \ 'tag':      l:tag,
        \ 'out':      [],
        \ 'err':      [],
        \ 'code':     -1,
        \ 'exited':   0,
        \ 'closed':   0,
        \ 'finished': 0,
        \ 'canceled': 0,
        \ 'timer':    -1,
        \ 'poll':     -1,
        \ 'polls':    0,
        \ 'job':      v:null,
        \ 'Callback': get(a:opts, 'on_done', v:null),
        \ }

  let l:job_opts = {
        \ 'out_mode': 'nl',
        \ 'out_cb':   function('s:on_out',   [l:run]),
        \ 'exit_cb':  function('s:on_exit',  [l:run]),
        \ 'close_cb': function('s:on_close', [l:run]),
        \ }
  " Merge stderr into stdout by default (see header: avoids losing stderr-only
  " output to a close_cb race). Opt out with merge_stderr=0 for a separate pipe.
  if get(a:opts, 'merge_stderr', 1)
    let l:job_opts.err_io = 'out'
  else
    let l:job_opts.err_mode = 'nl'
    let l:job_opts.err_cb   = function('s:on_err', [l:run])
  endif
  let l:job_opts.in_io = has_key(a:opts, 'stdin') ? 'pipe' : 'null'

  let l:run.job = job_start(a:cmd, l:job_opts)
  if !empty(l:tag)
    let s:active[l:tag] = l:run
  endif

  " Feed stdin, then close the write side so the compiler sees EOF and proceeds.
  if has_key(a:opts, 'stdin')
    let l:ch = job_getchannel(l:run.job)
    " List form is newline-terminated so the final line isn't dropped in nl mode.
    let l:data = type(a:opts.stdin) == type([]) ? join(a:opts.stdin, "\n") . "\n" : a:opts.stdin
    call ch_sendraw(l:ch, l:data)
    if exists('*ch_close_in')
      call ch_close_in(l:ch)
    else
      call ch_close(l:ch)
    endif
  endif

  let l:timeout = get(a:opts, 'timeout', 0)
  if l:timeout > 0
    let l:run.timer = timer_start(l:timeout, function('s:on_timeout', [l:run]))
  endif

  return l:run.job
endfunction

function! fakeide#job#stop(tag) abort
  if !has_key(s:active, a:tag)
    return
  endif
  let l:run = s:active[a:tag]
  let l:run.canceled = 1
  call s:detach(l:run)
  if l:run.job isnot v:null && job_status(l:run.job) ==# 'run'
    call job_stop(l:run.job, 'kill')
  endif
endfunction

function! fakeide#job#is_running(tag) abort
  return has_key(s:active, a:tag)
        \ && s:active[a:tag].job isnot v:null
        \ && job_status(s:active[a:tag].job) ==# 'run'
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
