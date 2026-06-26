#include <Python.h>

#include <cstdio>
#include <cstring>

int main() {
  const char* runtime_version = Py_GetVersion();
  if (std::strncmp(runtime_version, PY_VERSION, sizeof(PY_VERSION) - 1) != 0) {
    std::fprintf(stderr, "libpython reports %s but headers report %s\n",
                 runtime_version, PY_VERSION);
    return 1;
  }
  return 0;
}
