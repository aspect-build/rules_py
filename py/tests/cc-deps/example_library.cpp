#include <Python.h>

static PyObject *add(PyObject *, PyObject *args) {
  int left;
  int right;
  if (!PyArg_ParseTuple(args, "ii", &left, &right)) {
    return nullptr;
  }
  return PyLong_FromLong(left + right);
}

static PyObject *version_hex(PyObject *, PyObject *) {
  return PyLong_FromUnsignedLong(PY_VERSION_HEX);
}

static PyMethodDef methods[] = {
    {"add", add, METH_VARARGS, "Add two integers."},
    {"version_hex", version_hex, METH_NOARGS,
     "Return the Python header version used to compile this module."},
    {nullptr, nullptr, 0, nullptr},
};

static PyModuleDef module = {
    PyModuleDef_HEAD_INIT,
    "example_library",
    nullptr,
    -1,
    methods,
};

extern "C" {

PyMODINIT_FUNC PyInit_example_library() { return PyModule_Create(&module); }

}
