"""Exercise a PBS-backed venv from a Bazel action working directory."""

import argparse
import os
import subprocess
import sys
import tempfile


def _verify_prefixes(expected_cwd: str) -> None:
    assert os.path.samefile(os.getcwd(), expected_cwd), (os.getcwd(), expected_cwd)
    assert os.path.isabs(sys.base_prefix), sys.base_prefix
    assert os.path.isdir(sys.base_prefix), sys.base_prefix
    assert sys.base_prefix != "/install", sys.path

    pyvenv_cfg = os.path.join(os.path.dirname(sys.executable), "..", "pyvenv.cfg")
    with open(pyvenv_cfg, encoding="utf-8") as cfg:
        config = cfg.read().splitlines()
    assert "relocatable = true" in config, config
    home = next(
        (line.partition("=")[2].strip() for line in config if line.startswith("home =")),
        None,
    )

    expect_empty_home = os.name != "nt" and sys.version_info[:2] in {
        (3, 11),
        (3, 12),
    }
    assert (home == "") == expect_empty_home, (home, sys.version_info)
    if expect_empty_home:
        assert sys._base_executable != sys.executable, sys.executable
        assert os.path.samefile(
            os.path.dirname(os.path.dirname(sys._base_executable)),
            sys.base_prefix,
        ), (
            sys._base_executable,
            sys.base_prefix,
        )

    if not sys.flags.no_site:
        assert os.path.isabs(sys.prefix), sys.prefix
        assert os.path.isdir(sys.prefix), sys.prefix
        assert sys.prefix != sys.base_prefix, (sys.prefix, sys.base_prefix)

    stdlib = os.path.join(
        sys.base_prefix,
        "lib",
        f"python{sys.version_info.major}.{sys.version_info.minor}",
    )
    assert os.path.isdir(stdlib), (stdlib, sys.path)


def _verify_child(options: list[str], expected_cwd: str) -> None:
    subprocess.run(
        [
            sys.executable,
            *options,
            __file__,
            "--expected-cwd",
            expected_cwd,
        ],
        check=True,
    )


def _verify_nested_venv(expected_cwd: str) -> None:
    with tempfile.TemporaryDirectory(dir=expected_cwd) as root:
        child_venv = os.path.join(root, "child")
        subprocess.run(
            [sys.executable, "-m", "venv", "--without-pip", child_venv],
            cwd=expected_cwd,
            check=True,
        )

        with open(os.path.join(child_venv, "pyvenv.cfg"), encoding="utf-8") as cfg:
            child_config = cfg.read().splitlines()
        child_home = next(
            (
                line.partition("=")[2].strip()
                for line in child_config
                if line.startswith("home =")
            ),
            None,
        )
        assert child_home == os.path.dirname(os.path.abspath(sys._base_executable)), (
            child_home,
            sys._base_executable,
        )

        child_python = os.path.join(
            child_venv,
            "Scripts" if os.name == "nt" else "bin",
            "python.exe" if os.name == "nt" else "python",
        )
        subprocess.run(
            [
                child_python,
                "-c",
                "import encodings, os, sys; "
                "assert sys.base_prefix != '/install', sys.path; "
                "assert os.path.isdir(sys.base_prefix), sys.base_prefix; "
                "assert sys.prefix != sys.base_prefix, "
                "(sys.prefix, sys.base_prefix)",
            ],
            cwd=expected_cwd,
            check=True,
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-cwd", required=True)
    parser.add_argument("--test-children", action="store_true")
    args = parser.parse_args()

    _verify_prefixes(args.expected_cwd)
    if args.test_children:
        _verify_child([], args.expected_cwd)
        _verify_child(["-S"], args.expected_cwd)
        _verify_child(["-BS"], args.expected_cwd)
        _verify_nested_venv(args.expected_cwd)
