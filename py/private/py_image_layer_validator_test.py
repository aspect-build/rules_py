"""Tests for py_image_layer_validator."""

from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
from collections.abc import Iterator

from py.private.py_image_layer_validator import (
    _Suggestions,
    _find_large_files,
    _glob_for_file,
    _pkg_is_binary,
    _pkg_name_from_label,
    _pkg_size,
    _suggest_subpath_groups,
    main,
)


# ---------------------------------------------------------------------------
# _pkg_name_from_label
# ---------------------------------------------------------------------------


def test_pkg_name_pip_with_target() -> None:
    assert _pkg_name_from_label("@@pip//torch:torch") == "torch"


def test_pkg_name_pip_no_target() -> None:
    assert _pkg_name_from_label("@pip//numpy") == "numpy"


def test_pkg_name_canonical_pip() -> None:
    assert _pkg_name_from_label("@@aspect_rules_py++pip+whl_install__images__colorama__0_4_6//colorama") == "colorama"


def test_pkg_name_first_party_deep_path() -> None:
    # Should return the target name, not the full path
    assert _pkg_name_from_label("@@//my/deep/pkg:lib") == "lib"


def test_pkg_name_first_party_simple() -> None:
    assert _pkg_name_from_label("//my/pkg:mylib") == "mylib"


def test_pkg_name_hyphen_normalized() -> None:
    assert _pkg_name_from_label("@pip//my-package") == "my_package"


def test_pkg_name_at_prefix_stripped() -> None:
    assert _pkg_name_from_label("@pip//somelib:somelib") == "somelib"


# ---------------------------------------------------------------------------
# _glob_for_file
# ---------------------------------------------------------------------------


def test_glob_so_unversioned() -> None:
    assert _glob_for_file("libfoo.so") == "*.so"


def test_glob_so_versioned() -> None:
    assert _glob_for_file("libfoo.so.1.2.3") == "*.so.*"


def test_glob_so_versioned_single() -> None:
    assert _glob_for_file("libfoo.so.1") == "*.so.*"


def test_glob_so_does_not_match_readme_so_txt() -> None:
    # "README.so.txt" ends in .txt, not .so or .so.*, so glob_for_file
    # must NOT return a *.so* pattern for it.
    result = _glob_for_file("README.so.txt")
    assert result not in ("*.so*", "*.so", "*.so.*"), (
        "glob_for_file returned a .so pattern for README.so.txt: " + result
    )


def test_glob_pyd() -> None:
    assert _glob_for_file("_accel.pyd") == "*.pyd"


def test_glob_dylib() -> None:
    assert _glob_for_file("libbar.dylib") == "*.dylib"


def test_glob_dll() -> None:
    assert _glob_for_file("libbar.dll") == "*.dll"


def test_glob_py() -> None:
    assert _glob_for_file("module.py") == "*.py"


def test_glob_no_extension() -> None:
    assert _glob_for_file("binaryfile") == "binaryfile"


# ---------------------------------------------------------------------------
# _pkg_size / _find_large_files helpers
# ---------------------------------------------------------------------------


def _make_tmp_pkg(files: dict[str, bytes]) -> str:
    """Create a temp dir with given {relpath: content_bytes} and return its path."""
    d = tempfile.mkdtemp()
    for relpath, data in files.items():
        full = os.path.join(d, relpath)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as fh:
            fh.write(data)
    return d


def test_pkg_size_single_file() -> None:
    d = _make_tmp_pkg({"a.py": b"x" * 1000})
    assert _pkg_size([d]) == 1000


def test_pkg_size_multiple_files() -> None:
    d = _make_tmp_pkg({"a.py": b"x" * 500, "b.py": b"y" * 300})
    assert _pkg_size([d]) == 800


def test_pkg_size_empty_dir() -> None:
    d = tempfile.mkdtemp()
    assert _pkg_size([d]) == 0


def test_find_large_files_above_threshold() -> None:
    d = _make_tmp_pkg({"big.so": b"x" * 2000, "small.py": b"y" * 100})
    results = _find_large_files([d], min_bytes=1000)
    names = [r[0] for r in results]
    assert "big.so" in names
    assert "small.py" not in names


def test_find_large_files_sorted_by_size_desc() -> None:
    d = _make_tmp_pkg({
        "medium.so": b"x" * 2000,
        "large.so": b"x" * 5000,
        "tiny.py": b"x" * 1000,
    })
    results = _find_large_files([d], min_bytes=500)
    sizes = [r[1] for r in results]
    assert sizes == sorted(sizes, reverse=True)


# ---------------------------------------------------------------------------
# _pkg_is_binary
# ---------------------------------------------------------------------------


def test_pkg_is_binary_true() -> None:
    d = _make_tmp_pkg({
        "foo-1.0.dist-info/WHEEL": b"Wheel-Version: 1.0\nRoot-Is-Purelib: false\n",
    })
    assert _pkg_is_binary([d]) is True


def test_pkg_is_binary_false_for_pure() -> None:
    d = _make_tmp_pkg({
        "foo-1.0.dist-info/WHEEL": b"Wheel-Version: 1.0\nRoot-Is-Purelib: true\n",
    })
    assert _pkg_is_binary([d]) is False


def test_pkg_is_binary_false_no_wheel_file() -> None:
    d = _make_tmp_pkg({"foo/__init__.py": b""})
    assert _pkg_is_binary([d]) is False


# ---------------------------------------------------------------------------
# _suggest_subpath_groups
# ---------------------------------------------------------------------------


def test_suggest_subpath_groups_large_so() -> None:
    d = _make_tmp_pkg({"libfoo.so": b"x" * (30 * 1024 * 1024)})
    results = _suggest_subpath_groups("@pip//mylib", [d], min_file_bytes=10 * 1024 * 1024)
    keys = [r[0] for r in results]
    assert any("*.so" in k for k in keys)


def test_suggest_subpath_groups_no_large_files() -> None:
    d = _make_tmp_pkg({"small.py": b"x" * 100})
    results = _suggest_subpath_groups("@pip//mylib", [d], min_file_bytes=10 * 1024 * 1024)
    assert results == []


def test_suggest_subpath_groups_key_format() -> None:
    d = _make_tmp_pkg({"libfoo.so": b"x" * (30 * 1024 * 1024)})
    results = _suggest_subpath_groups("@pip//mylib", [d], min_file_bytes=1 * 1024 * 1024)
    assert len(results) > 0
    groups_key, group_name, display_line, is_binary = results[0]
    assert groups_key.startswith("@pip//mylib:")
    assert "mylib" in group_name
    assert display_line.startswith("        ")
    assert is_binary is True


# ---------------------------------------------------------------------------
# _Suggestions deduplication
# ---------------------------------------------------------------------------


def test_suggestions_whole_then_subpath_wins() -> None:
    s = _Suggestions()
    s.add_group("@pip//torch", '        "@pip//torch": "torch",')
    s.add_group("@pip//torch:*.so", '        "@pip//torch:*.so": "torch_so",')
    assert "@pip//torch" not in s.group_lines
    assert "@pip//torch:*.so" in s.group_lines


def test_suggestions_subpath_blocks_whole() -> None:
    s = _Suggestions()
    s.add_group("@pip//torch:*.so", '        "@pip//torch:*.so": "torch_so",')
    s.add_group("@pip//torch", '        "@pip//torch": "torch",')
    # whole-package add is a no-op when a subpath already exists
    assert "@pip//torch" not in s.group_lines
    assert "@pip//torch:*.so" in s.group_lines


def test_suggestions_compression_deduped() -> None:
    s = _Suggestions()
    s.add_compression("@pip//torch", "1")
    s.add_compression("@pip//torch", "9")
    assert s.compression["@pip//torch"] == "1"


# ---------------------------------------------------------------------------
# main() integration
# ---------------------------------------------------------------------------


@contextlib.contextmanager
def _capture_stderr() -> Iterator[io.StringIO]:
    buf = io.StringIO()
    old = sys.stderr
    sys.stderr = buf
    try:
        yield buf
    finally:
        sys.stderr = old


def test_main_ok_below_threshold() -> None:
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        out_path = f.name
    sys.argv = ["validator", "--threshold_mb", "500", "--output", out_path]
    try:
        main()
    except SystemExit as e:
        assert e.code == 0 or e.code is None
    finally:
        with open(out_path) as fh:
            content = fh.read()
        assert "OK" in content
        os.unlink(out_path)


def test_main_layer_count_error() -> None:
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        out_path = f.name
    sys.argv = [
        "validator",
        "--threshold_mb", "999",
        "--layer_count", "200",
        "--output", out_path,
    ]
    with _capture_stderr():
        try:
            main()
            exit_code = 0
        except SystemExit as e:
            exit_code = e.code
    assert exit_code == 1
    with open(out_path) as fh:
        content = fh.read()
    assert "ERROR" in content
    assert "127" in content
    os.unlink(out_path)


def test_main_layer_count_warning() -> None:
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        out_path = f.name
    sys.argv = [
        "validator",
        "--threshold_mb", "999",
        "--layer_count", "100",
        "--warn_layer_count", "90",
        "--output", out_path,
    ]
    with _capture_stderr():
        try:
            main()
            exit_code = 0
        except SystemExit as e:
            exit_code = e.code
    assert exit_code == 0
    with open(out_path) as fh:
        content = fh.read()
    assert "WARNING" in content
    os.unlink(out_path)


def test_main_squashed_layer_error() -> None:
    big_dir = _make_tmp_pkg({"big.py": b"x" * (300 * 1024 * 1024)})
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        out_path = f.name
    sys.argv = [
        "validator",
        "--threshold_mb", "200",
        "--output", out_path,
        "@pip//bigpkg=" + big_dir,
    ]
    with _capture_stderr():
        try:
            main()
            exit_code = 0
        except SystemExit as e:
            exit_code = e.code
    assert exit_code == 1
    with open(out_path) as fh:
        content = fh.read()
    assert "ERROR" in content
    assert "squashed pip layer" in content
    os.unlink(out_path)


if __name__ == "__main__":
    failures = []
    test_fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in test_fns:
        try:
            fn()
            print(f"  PASS  {fn.__name__}")
        except Exception as e:
            print(f"  FAIL  {fn.__name__}: {e}")
            failures.append(fn.__name__)

    total = len(test_fns)
    passed = total - len(failures)
    print(f"\n{passed} passed, {len(failures)} failed (of {total})")
    if failures:
        print(f"Failures: {', '.join(failures)}")
        sys.exit(1)
