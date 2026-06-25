"""Run buildifier without touching generated snapshots."""

import os
from pathlib import Path
import subprocess
import sys

_DISCOVER_ARGUMENT = "--rules-py-discover"
# Aspect directly spawns formatter executables with only its computed
# arguments, so py_binary.args cannot carry this data label's runfiles path:
# https://github.com/aspect-build/aspect-cli/blob/efa2bc8def40def4934c15b1eece297c17bb6b3e/crates/aspect-cli/src/builtins/aspect/lib/runnable.axl#L373-L404
# @buildifier_prebuilt//buildifier declares buildifier/buildifier:
# https://github.com/keith/buildifier-prebuilt/blob/bf945a59eaa436c8b4857774ae724b4c31a08643/buildifier/buildifier_binary.bzl#L7-L20
_BUILDIFIER_RLOCATION = "buildifier_prebuilt/buildifier/buildifier"
_STARLARK_FILENAMES = {
    "BUCK",
    "BUILD",
    "BUILD.bazel",
    "MODULE.bazel",
    "Tiltfile",
    "WORKSPACE",
    "WORKSPACE.bazel",
}
_STARLARK_SUFFIXES = (".MODULE.bazel", ".axl", ".bzl", ".star")


def _discover_files(root: Path) -> list[str]:
    for workspace_root in (root, *root.parents):
        if (workspace_root / ".git").exists():
            break
    else:
        workspace_root = root
    if "snapshots" in root.relative_to(workspace_root).parts:
        return []

    files = []
    for directory, dirnames, filenames in os.walk(root):
        # Per https://docs.python.org/3/library/os.html#os.walk:
        #
        # When topdown is True, the caller can modify the dirnames list
        # in-place to prune the search.
        dirnames[:] = [name for name in dirnames if name not in {".git", "snapshots"}]
        directory = Path(directory)
        for filename in filenames:
            if filename not in _STARLARK_FILENAMES and not filename.endswith(
                _STARLARK_SUFFIXES
            ):
                continue
            files.append(str((directory / filename).relative_to(root)))
    return files


def main() -> int:
    from python.runfiles import runfiles

    arguments = sys.argv[1:]
    discover = not arguments or _DISCOVER_ARGUMENT in arguments
    arguments = [argument for argument in arguments if argument != _DISCOVER_ARGUMENT]
    if discover:
        files = _discover_files(Path.cwd())
        if not files:
            return 0
        arguments.extend(files)

    runtime_files = runfiles.Create()
    if runtime_files is None:
        raise RuntimeError("cannot locate buildifier runfiles")
    buildifier = runtime_files.Rlocation(_BUILDIFIER_RLOCATION)
    if buildifier is None:
        raise RuntimeError("cannot locate the buildifier executable")
    return subprocess.call([buildifier, *arguments])


if __name__ == "__main__":
    sys.exit(main())
