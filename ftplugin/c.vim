" ftplugin/c.vim — wire fake-ide into C buffers.
if get(b:, 'fakeide_c_loaded', 0)
  finish
endif
let b:fakeide_c_loaded = 1
call fakeide#enable()
