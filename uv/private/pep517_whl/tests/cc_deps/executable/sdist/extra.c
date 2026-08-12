/* Compiled by setuptools' build_clib (declared via setup(libraries=...)) into
 * libextra.a inside the wheel build, before build_ext runs (hermetically, by
 * the same configured toolchain). dep.c (outside the sdist, linked via cc_deps)
 * forward-declares and calls extra_value(); the -lextra that resolves it is
 * injected through the cc_deps [build_ext] libraries slot. */
int extra_value(int x) { return x + 10; }
