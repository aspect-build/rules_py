"""Run a Python type checker for rules_py's type-check validation action.

Invoked by the PyTypeCheck action declared in type_check.bzl. Builds the
checker's command line from the toolchain's conventions, runs it, and writes
its output to the action's log. A failing check exits non-zero with the
output on stderr, so it lands in the build log.

Search paths arrive as runfiles-relative import roots (`--import`) plus the
distinct roots of the action's inputs (`--root`). Each pair is mapped to an
execroot path, and only directories that exist are passed on: checkers such
as ty reject search paths that don't exist.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile


def _parse_args(argv):
    parser = argparse.ArgumentParser(fromfile_prefix_chars="@")
    parser.add_argument("--output", required=True)
    parser.add_argument("--checker", required=True)
    parser.add_argument("--workspace-name", required=True)
    parser.add_argument("--python-version")
    parser.add_argument("--python-version-flag")
    parser.add_argument("--config")
    parser.add_argument("--config-flag")
    parser.add_argument("--search-path-flag")
    parser.add_argument("--search-path-env")
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--arg", action="append", default=[])
    parser.add_argument("--path", dest="paths", action="append", default=[])
    parser.add_argument("--import", dest="imports", action="append", default=[])
    parser.add_argument("--root", dest="roots", action="append", default=[])
    parser.add_argument("--src", dest="srcs", action="append", default=[])
    return parser.parse_args(argv)


def _search_paths(workspace_name, exec_paths, imports, roots):
    """Map runfiles-relative import roots to existing execroot directories.

    `exec_paths` are already execroot-relative and come first.
    """
    rels = []
    for imp in imports:
        repo, _, rest = imp.partition("/")
        rels.append(rest if repo == workspace_name else os.path.join("external", imp))
    # The venv also puts the runfiles root itself on sys.path, so
    # `import <repo>.<package>` resolves for external repositories (e.g.
    # `bazel_tools.tools.python.runfiles`). In the execroot that's `external/`;
    # it goes last so the narrower roots win.
    rels.append("external")
    candidates = exec_paths + [os.path.join(root, rel) for rel in rels for root in roots]

    paths = []
    seen = set()
    for path in candidates:
        path = os.path.normpath(path)
        if path not in seen and os.path.isdir(path):
            seen.add(path)
            paths.append(path)
    return paths


def _empty_python_prefix(scratch, python_version):
    """A Python installation layout with nothing in site-packages."""
    if not python_version:
        sys.exit(
            "run_checker: the type checker toolchain uses {empty_python_prefix}, "
            "but the target's Python version is unknown"
        )
    prefix = os.path.join(scratch, "python")
    # POSIX and Windows installations lay out site-packages differently.
    os.makedirs(os.path.join(prefix, "lib", "python" + python_version, "site-packages"))
    os.makedirs(os.path.join(prefix, "Lib", "site-packages"), exist_ok=True)
    return prefix


def main(argv):
    opts = _parse_args(argv)
    scratch = tempfile.mkdtemp(prefix="py_type_check_")
    try:
        placeholders = {"{scratch}": os.path.join(scratch, "work")}
        os.makedirs(placeholders["{scratch}"])

        def substitute(value):
            if "{empty_python_prefix}" in value and "{empty_python_prefix}" not in placeholders:
                placeholders["{empty_python_prefix}"] = _empty_python_prefix(scratch, opts.python_version)
            for key, replacement in placeholders.items():
                value = value.replace(key, replacement)
            return value

        env = dict(os.environ)
        # Keep the checker from picking up the host's Python environment or
        # per-user configuration.
        for name in ("VIRTUAL_ENV", "CONDA_PREFIX", "PYTHONPATH", "PYTHONHOME", "MYPYPATH"):
            env.pop(name, None)
        env["XDG_CONFIG_HOME"] = os.path.join(scratch, "config")
        for entry in opts.env:
            name, _, value = entry.partition("=")
            env[name] = substitute(value)

        cmd = [opts.checker] + [substitute(a) for a in opts.arg]
        if opts.python_version and opts.python_version_flag:
            cmd += [opts.python_version_flag, opts.python_version]
        if opts.config:
            cmd += [opts.config_flag, opts.config]

        search_paths = _search_paths(opts.workspace_name, opts.paths, opts.imports, opts.roots)
        if opts.search_path_flag:
            for path in search_paths:
                cmd += [opts.search_path_flag, path]
        else:
            env[opts.search_path_env] = os.pathsep.join(search_paths)

        cmd += opts.srcs

        result = subprocess.run(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    with open(opts.output, "w") as f:
        f.write(result.stdout)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        return result.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
