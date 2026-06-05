" after/ftplugin/c.vim — re-assert fake-ide's omnifunc after Vim's built-in
" $VIMRUNTIME/ftplugin/c.vim, which sets omnifunc=ccomplete#Complete and would
" otherwise clobber the value our ftplugin/c.vim set. after/ftplugin runs LAST.
if get(b:, 'fakeide_active', 0)
  setlocal omnifunc=fakeide#complete#omni
endif
