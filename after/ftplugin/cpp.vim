" after/ftplugin/cpp.vim — re-assert fake-ide's omnifunc after Vim's built-in
" $VIMRUNTIME/ftplugin/cpp.vim, which sets omnifunc=ccomplete#Complete and would
" otherwise clobber the value our ftplugin/cpp.vim set. after/ftplugin runs LAST.
if get(b:, 'fakeide_active', 0)
  setlocal omnifunc=fakeide#complete#omni
endif
