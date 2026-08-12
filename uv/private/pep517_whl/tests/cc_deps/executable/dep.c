#include "dep.h"

#include "dep2.h"

/* extra_value() is defined in extra.c INSIDE the sdist, where setuptools'
 * build_clib compiles it into libextra.a during the wheel build (hermetic: no
 * host library involved). Only a forward declaration here: the `dep` cc_library
 * carries linkopts = ["-lextra"], which cc_deps routes through the setuptools
 * [build_ext] libraries slot; the sdist's build_clib subclass suppresses
 * distutils' auto -l<name> for clib libraries, so dropping that linkopt leaves
 * extra_value undefined at import. The [build_ext] libraries slot is what
 * carries the link. */
extern int extra_value(int x);

/* dep_value() calls through the transitive leaf dep2_value() and the
 * build_clib-built extra_value() on an argument-derived value (extra_value is
 * external, so the call cannot be folded): a wheel that imports and returns the
 * expected value proves both archives linked in order AND that -lextra reached
 * the link through the [build_ext] libraries slot. */
int dep_value(int x) { return dep2_value() + extra_value(x); }
