" ftplugin/cpp.vim — wire fake-ide into C++ buffers.
if get(b:, 'fakeide_cpp_loaded', 0)
  finish
endif
let b:fakeide_cpp_loaded = 1
call fakeide#enable()
