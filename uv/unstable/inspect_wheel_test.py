#!/usr/bin/env python3
"""Unit tests for the wheel inspection logic embedded in gazelle.bzl.

The logic under test lives in `_WHEEL_INSPECT_SCRIPT` inside
`uv/unstable/gazelle.bzl`. Because that script is a Starlark string literal,
it cannot be imported directly. The `inspect_wheel` function below is a
verbatim copy — keep it in sync with the original.
"""

import io
import zipfile


def inspect_wheel(whl_name, zf_source):
    """Mirror of inspect_wheel() from _WHEEL_INSPECT_SCRIPT in gazelle.bzl."""
    mapping = {}
    pkg_name = whl_name.split("-")[0].lower().replace("-", "_")

    with zipfile.ZipFile(zf_source, "r") as zf:
        top_level = None
        for name in zf.namelist():
            if name.endswith("top_level.txt"):
                top_level = name
                break

        use_top_level = False
        if top_level:
            content = zf.read(top_level).decode("utf-8").strip()
            if content:
                use_top_level = True
                for line in content.split("\n"):
                    line = line.strip()
                    if line and not line.startswith("#"):
                        mapping[line] = pkg_name

        if not use_top_level:
            top_dirs = set()
            for name in zf.namelist():
                parts = name.split("/")
                if parts:
                    top_dir = parts[0]
                    if top_dir.endswith(".dist-info") or top_dir.endswith(".data"):
                        continue
                    if "." in top_dir and not top_dir.startswith("."):
                        continue
                    top_dirs.add(top_dir)
            for top_dir in top_dirs:
                mapping[top_dir] = pkg_name

    return mapping


def _make_wheel(whl_name, top_level_txt=None, files=None):
    """Return a BytesIO containing a minimal .whl (ZIP) archive."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        if top_level_txt is not None:
            dist_name = whl_name.split("-")[0]
            zf.writestr(f"{dist_name}-1.0.dist-info/top_level.txt", top_level_txt)
        for path in (files or []):
            zf.writestr(path, "")
    buf.seek(0)
    return buf


def _run(whl_name, **kwargs):
    return inspect_wheel(whl_name, _make_wheel(whl_name, **kwargs))


def test_top_level_txt_is_used():
    assert _run("cowsay-6.1-py3-none-any.whl", top_level_txt="cowsay\n") == {"cowsay": "cowsay"}


def test_top_level_txt_multiple_modules():
    result = _run("mypackage-1.0-py3-none-any.whl", top_level_txt="mypackage\n_internal\n")
    assert result == {"mypackage": "mypackage", "_internal": "mypackage"}


def test_top_level_txt_comments_skipped():
    result = _run("pkg-1.0-py3-none-any.whl", top_level_txt="# auto-generated\npkg\n")
    assert result == {"pkg": "pkg"}


def test_empty_top_level_txt_falls_back_to_dir_scan():
    result = _run(
        "mylib-1.0-py3-none-any.whl",
        top_level_txt="",
        files=["mylib/__init__.py", "mylib/utils.py"],
    )
    assert result == {"mylib": "mylib"}


def test_no_top_level_txt_uses_dir_scan():
    result = _run(
        "requests-2.0-py3-none-any.whl",
        files=["requests/__init__.py", "requests/adapters.py"],
    )
    assert result == {"requests": "requests"}


def test_dist_info_excluded_from_dir_scan():
    result = _run(
        "requests-2.0-py3-none-any.whl",
        files=[
            "requests/__init__.py",
            "requests-2.0.dist-info/METADATA",
            "requests-2.0.dist-info/WHEEL",
        ],
    )
    assert result == {"requests": "requests"}


def test_data_dir_excluded_from_dir_scan():
    result = _run(
        "mypkg-1.0-py3-none-any.whl",
        files=["mypkg/__init__.py", "mypkg-1.0.data/purelib/mypkg/__init__.py"],
    )
    assert result == {"mypkg": "mypkg"}


def test_root_dotted_files_excluded_from_dir_scan():
    result = _run(
        "simplepkg-1.0-py3-none-any.whl",
        files=["simplepkg/__init__.py", "LICENSE.txt", "README.md"],
    )
    assert result == {"simplepkg": "simplepkg"}


def test_hyphenated_package_name_normalized():
    # PyPI normalizes hyphens to underscores in wheel filenames, so the
    # filename is django_crontab-... not django-crontab-...
    result = _run(
        "django_crontab-0.7.1-py3-none-any.whl",
        top_level_txt="django_crontab\n",
    )
    assert result == {"django_crontab": "django_crontab"}


def test_multiple_wheels_same_package():
    result = _run(
        "pydantic-2.0-py3-none-any.whl",
        top_level_txt="pydantic\npydantic_core\n",
    )
    assert result == {"pydantic": "pydantic", "pydantic_core": "pydantic"}


if __name__ == "__main__":
    import sys

    tests = [(k, v) for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
            passed += 1
        except Exception as e:
            print(f"FAIL {name}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
