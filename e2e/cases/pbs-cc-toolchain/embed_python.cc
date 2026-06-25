#include <Python.h>

#include <cstring>

int main() {
  return std::strncmp(Py_GetVersion(), PY_VERSION, sizeof(PY_VERSION) - 1) == 0
             ? 0
             : 1;
}
