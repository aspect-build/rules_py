#include <nanobind/nanobind.h>
#include <nanobind/stl/string.h>

// A minimal nanobind extension. See BUILD.bazel for what it guards (issue #1095).
NB_MODULE(example_ext, m) {
    m.def("add", [](int a, int b) { return a + b; });
    m.def("greet", [](const std::string &name) { return "Hello, " + name + "!"; });
}
