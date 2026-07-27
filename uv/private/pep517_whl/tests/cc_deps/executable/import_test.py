"""Import a real setuptools extension built via pep517_native_whl(cc_deps=...).

End-to-end proof that, after the setuptools backend changes into the unpacked
sdist:
  * <dep.h> resolved through the cc_deps include path (CPPFLAGS) even though the
    header is deliberately absent from the sdist,
  * dep_value() linked through the post-object cc_deps archive slot,
  * the transitive leaf dep2_value() linked too,
  * -lextra reached the link through the [build_ext] libraries slot, resolving
    against the libextra.a the sdist's own build_clib compiled in-build, and
  * -lgroup_a, -lgroup_b, -lgroup_a retained their relative order through the
    [build_ext] libraries slot, resolving a deliberate one-pass archive cycle
    via the documented repeat-the-library workaround, and
  * MOD_BONUS arrived via a transitively-propagated cc_deps -D define.

The module is loaded from the freshly extracted wheel (asserted via __file__),
so a stale ambient build cannot satisfy the test.
"""

import glob
import os
import sys
import zipfile

import runfiles

_WHL_DIR = "_main/uv/private/pep517_whl/tests/cc_deps/executable/whl"


def main() -> None:
    r = runfiles.Create()
    assert r is not None, "runfiles unavailable"

    whl_dir = r.Rlocation(_WHL_DIR)
    assert whl_dir and os.path.isdir(whl_dir), "wheel output dir missing: {}".format(whl_dir)

    wheels = glob.glob(os.path.join(whl_dir, "*.whl"))
    assert len(wheels) == 1, "expected exactly one wheel, got {}".format(wheels)

    extract_dir = os.path.join(os.environ["TEST_TMPDIR"], "wheel_extract")
    with zipfile.ZipFile(wheels[0]) as archive:
        archive.extractall(extract_dir)

    sys.path.insert(0, extract_dir)
    import cc_deps_ext

    # The extension .so must come from the wheel we just extracted, not from any
    # ambient copy that happened to be importable.
    module_file = os.path.realpath(cc_deps_ext.__file__)
    assert module_file.startswith(os.path.realpath(extract_dir) + os.sep), \
        "module loaded from unexpected location: {}".format(module_file)

    result = cc_deps_ext.value()
    # dep_value(7) = dep2_value() 40 + extra_value(7) 17 (7 + 10, via -lextra);
    # MOD_BONUS contributes 2; and the ordered cyclic archives contribute 125
    # (group_entry 100 + group_b 20 + group_a_tail 5). Each contribution is
    # distinct: 40 + 17 + 2 + 125 == 184.
    expected = 40 + (7 + 10) + 2 + 125
    assert result == expected, \
        "expected cc_deps_ext.value() == {} (dep2 40 + extra 17 + MOD_BONUS 2 + group 125), got {}".format(
            expected, result)

    print("ok: cc_deps_ext.value() == {} loaded from {}".format(result, module_file))


if __name__ == "__main__":
    main()
