"""A minimal real-setuptools extension linking an out-of-tree cc_library.

The extension source #includes <dep.h>, which is deliberately absent from this
sdist: it is resolved only through the cc_deps include path (CPPFLAGS), and the
dep_value symbol it calls is resolved only through the cc_deps static archives
that setuptools places in the post-object link slot ([build_ext] link_objects).
Neither Extension include_dirs nor Extension libraries are set on purpose.

libextra.a, libgroup_a.a, and libgroup_b.a are built hermetically by build_clib
(with the same configured compiler, before build_ext runs). The group archives
contain a deliberate one-pass cycle, so they link only when -lgroup_a is repeated
after -lgroup_b (the documented repeat-the-library workaround), which exercises
-l order preservation through the [build_ext] libraries slot."""

from setuptools import Extension, setup
from setuptools.command.build_clib import build_clib


class quiet_build_clib(build_clib):
    """Build the test archives but hide their names from build_ext's auto-link.

    distutils' build_ext.run() extends its libraries with
    build_clib.get_library_names(), which would link these archives even without
    the cc_deps user_link_flags under test. Returning no names keeps the archives
    and library_dirs entry while leaving all -l naming and ordering exclusively
    to the injected CcInfo stream."""

    def get_library_names(self) -> list:
        return []


setup(
    cmdclass={"build_clib": quiet_build_clib},
    libraries=[
        ("extra", {"sources": ["extra.c"]}),
        ("group_a", {"sources": ["group_a_entry.c", "group_a_tail.c"]}),
        ("group_b", {"sources": ["group_b.c"]}),
    ],
    ext_modules=[
        Extension(
            name="cc_deps_ext",
            sources=["mod.c"],
        ),
    ],
)
