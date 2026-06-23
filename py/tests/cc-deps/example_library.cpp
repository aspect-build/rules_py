
#include <Python.h>

static PyObject *answer(PyObject *, PyObject *) { return PyLong_FromLong(42); }

static PyMethodDef methods[] = {
    {"answer", answer, METH_NOARGS, nullptr},
    {nullptr, nullptr, 0, nullptr},
};

static PyModuleDef module = {
    PyModuleDef_HEAD_INIT,
    "native_module",
    nullptr,
    -1,
    methods,
};

PyMODINIT_FUNC PyInit_native_module() { return PyModule_Create(&module); }
