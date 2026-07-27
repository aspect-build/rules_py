/* A hand-rolled CPython extension module.
 *
 * <dep.h> is resolved via the cc_deps include path, not from inside the sdist;
 * dep_value() links through the cc_deps static archives (dep -> dep2) plus the
 * [build_ext] libraries slot (-lextra against the build_clib-built libextra.a);
 * and MOD_BONUS arrives as a transitively-propagated cc_deps -D define.
 * group_entry() additionally proves that the -l entries keep their relative
 * order through setuptools' [build_ext] libraries slot: the group archives form
 * a one-pass cycle resolved by repeating -lgroup_a after -lgroup_b.
 * Expected value: dep2 40 + extra 17 + MOD_BONUS 2 + group 125 == 184. */
#include <Python.h>

#include <dep.h>

long group_entry(void);

/* MOD_BONUS is injected by the `dep` cc_library's defines = ["MOD_BONUS=2"],
 * which propagate transitively into this backend compile via cc_deps CPPFLAGS.
 * Its absence means the -D define propagation broke, so fail the compile loudly
 * rather than silently linking a wheel with the wrong value. */
#ifndef MOD_BONUS
#error "MOD_BONUS not defined: cc_deps -D define propagation is broken"
#endif

static PyObject *cc_deps_ext_value(PyObject *self, PyObject *args) {
    (void)self;
    (void)args;
    return PyLong_FromLong(dep_value(7) + MOD_BONUS + group_entry());
}

static PyMethodDef cc_deps_ext_methods[] = {
    {"value", cc_deps_ext_value, METH_NOARGS,
     "Return dep_value() from the linked cc_library chain."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef cc_deps_ext_module = {
    PyModuleDef_HEAD_INIT, "cc_deps_ext", NULL, -1, cc_deps_ext_methods,
    NULL, NULL, NULL, NULL,
};

PyMODINIT_FUNC PyInit_cc_deps_ext(void) {
    return PyModule_Create(&cc_deps_ext_module);
}
