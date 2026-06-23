#include <Python.h>

int main() {
    return Py_IsInitialized() < 0;
}
