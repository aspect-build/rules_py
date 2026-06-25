#define Py_LIMITED_API 0x03080000
#include <Python.h>

static PyObject *add(PyObject *, PyObject *args) {
  int left;
  int right;
  if (!PyArg_ParseTuple(args, "ii", &left, &right)) {
    return nullptr;
  }
  return PyLong_FromLong(left + right);
}

static PyMethodDef methods[] = {
    {"add", add, METH_VARARGS, "Add two integers."},
    {nullptr, nullptr, 0, nullptr},
};

static PyModuleDef module = {
    PyModuleDef_HEAD_INIT,
    "limited_api_library",
    nullptr,
    -1,
    methods,
};

extern "C" {

PyMODINIT_FUNC PyInit_limited_api_library() {
  return PyModule_Create(&module);
}

}
