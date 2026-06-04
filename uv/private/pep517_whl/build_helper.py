#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from argparse import ArgumentParser
import os
import shutil
import sys
from os import listdir, mkdir, path
from subprocess import CalledProcessError, check_call, STDOUT, run
from tempfile import TemporaryFile

PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
PARSER.add_argument("--subdirectory", default="", help="Subdirectory within the archive containing pyproject.toml")
opts, args = PARSER.parse_known_args()

tmp_root = opts.outdir.lstrip("/") + ".tmp"
mkdir(tmp_root)

t = path.join(tmp_root, "worktree")

shutil.unpack_archive(opts.srcarchive, t)

# Annoyingly, unpack_archive creates a subdir in the target. Update t
# accordingly. Not worth the eng effort to prevent creating this dir.
t = path.join(t, listdir(t)[0])

# If a subdirectory is specified (e.g. for monorepo archives), descend into it.
if opts.subdirectory:
    t = path.join(t, opts.subdirectory)

if opts.patches:
    for patch_file in opts.patches:
        check_call(
            ["patch", "-p{}".format(opts.patch_strip), "-i", path.abspath(patch_file)],
            cwd=t,
        )


def _ensure_build_backend(src_dir):
    """Patch pyproject.toml and generate setup.cfg if needed for buildability."""
    import importlib.metadata

    pyproject_path = path.join(src_dir, "pyproject.toml")
    if not path.exists(pyproject_path):
        return

    # Minimal TOML parsing
    lines = []
    with open(pyproject_path) as f:
        lines = f.readlines()

    # Parse [project] name, version and [build-system] build-backend
    name = None
    version = None
    build_backend = None
    in_project = False
    in_build_system = False
    in_project_scripts = False
    has_src_layout = path.isdir(path.join(src_dir, "src"))
    scripts = {}

    for line in lines:
        stripped = line.strip()
        if stripped == "[project]":
            in_project = True
            in_build_system = False
            in_project_scripts = False
            continue
        elif stripped == "[build-system]":
            in_build_system = True
            in_project = False
            in_project_scripts = False
            continue
        elif stripped == "[project.scripts]":
            in_project_scripts = True
            in_project = False
            in_build_system = False
            continue
        elif stripped.startswith("["):
            in_project = False
            in_build_system = False
            in_project_scripts = False
            continue
        if in_project:
            if stripped.startswith("name"):
                _, _, val = stripped.partition("=")
                name = val.strip().strip('"').strip("'")
            elif stripped.startswith("version"):
                _, _, val = stripped.partition("=")
                version = val.strip().strip('"').strip("'")
        elif in_build_system:
            if stripped.startswith("build-backend"):
                _, _, val = stripped.partition("=")
                build_backend = val.strip().strip('"').strip("'")
        elif in_project_scripts:
            if "=" in stripped:
                script_name, _, script_val = stripped.partition("=")
                scripts[script_name.strip().strip('"').strip("'")] = script_val.strip().strip('"').strip("'")

    # Check if the declared build backend is importable
    backend_available = True
    if build_backend and build_backend != "setuptools.build_meta":
        backend_module = build_backend.split(":")[0].split(".")[0]
        try:
            __import__(backend_module)
        except ImportError:
            backend_available = False

    # If backend is unavailable, rewrite pyproject.toml to use setuptools
    if not backend_available:
        new_lines = []
        in_build_system_section = False
        for line in lines:
            stripped = line.strip()
            if stripped == "[build-system]":
                in_build_system_section = True
                new_lines.append("[build-system]\n")
                new_lines.append('requires = ["setuptools", "wheel"]\n')
                new_lines.append('build-backend = "setuptools.build_meta"\n')
                continue
            elif stripped.startswith("[") and in_build_system_section:
                in_build_system_section = False
            if in_build_system_section:
                continue  # skip original build-system lines
            new_lines.append(line)
        with open(pyproject_path, "w") as f:
            f.writelines(new_lines)
        build_backend = "setuptools.build_meta"

    # For setuptools.build_meta, ensure metadata is available
    if build_backend == "setuptools.build_meta" or build_backend is None:
        try:
            st_ver = tuple(int(x) for x in importlib.metadata.version("setuptools").split(".")[:2])
        except Exception:
            st_ver = (0, 0)

        setup_cfg_path = path.join(src_dir, "setup.cfg")
        need_setup_cfg = st_ver < (61, 0) and name and version
        if need_setup_cfg and not path.exists(setup_cfg_path):
            cfg_content = "[metadata]\nname = {}\nversion = {}\n".format(name, version)
            # Add package discovery for src-layout
            if has_src_layout:
                cfg_content += "\n[options]\npackage_dir =\n    = src\npackages = find:\n\n[options.packages.find]\nwhere = src\n"
            else:
                cfg_content += "\n[options]\npackages = find:\n"
            # Include all non-Python data files in packages
            cfg_content += "\n[options.package_data]\n* = *\n"
            # Add entry points (console_scripts) from [project.scripts]
            if scripts:
                cfg_content += "\n[options.entry_points]\nconsole_scripts =\n"
                for script_name, script_val in scripts.items():
                    cfg_content += "    {} = {}\n".format(script_name, script_val)
            with open(setup_cfg_path, "w") as f:
                f.write(cfg_content)

_ensure_build_backend(t)

# Get a path to the outdir which will be valid after we cd
outdir = path.abspath(opts.outdir)

# Resolve CC/CXX to absolute paths so they remain valid after cwd changes
# into the extracted source tree (Bazel sets these as exec-root-relative).
for _cc_var in ("CC", "CXX"):
    if _cc_var in os.environ and not path.isabs(os.environ[_cc_var]):
        os.environ[_cc_var] = path.abspath(os.environ[_cc_var])

# Preserve PATH so native sdist builds can find compilers (clang, gcc).
build_env = dict(os.environ)
build_env.update({
    "TMP": tmp_root,
    "TEMP": tmp_root,
    "TEMPDIR": tmp_root,
    # Bazel sets file timestamps to epoch 0 for reproducibility. wheel < 0.38
    # fails when creating ZIP files with timestamps before 1980. Setting
    # SOURCE_DATE_EPOCH to 1980-01-01 avoids this issue.
    "SOURCE_DATE_EPOCH": "315532800",
})

if path.exists(path.join(t, "pyproject.toml")) or path.exists(path.join(t, "setup.py")):
    # Always use `python -m build` (PEP 517 frontend). For setup.py-only
    # packages without a pyproject.toml, build creates a minimal PEP 517
    # shim automatically. --no-isolation ensures it uses the deps we've
    # already provided in the build venv rather than trying to pip-install.
    cmd = [
        sys.executable,
        "-m", "build",
        "--wheel",
        "--no-isolation",
        "--skip-dependency-check",
        "--outdir", outdir,
    ]

else:
    print("Error: Unable to detect build command! Neither pyproject.toml nor setup.py found!", file=sys.stderr)
    exit(1)

with TemporaryFile(mode="w+") as build_log:
    try:
        run(cmd, cwd=t, env=build_env, stdout=build_log, stderr=STDOUT, check=True)
    except CalledProcessError:
        build_log.seek(0)
        output = build_log.read()
        if output:
            sys.stderr.write(output)
            if not output.endswith("\n"):
                sys.stderr.write("\n")
        print("Error: Build failed!\nSee {} for the sandbox".format(t), file=sys.stderr)
        exit(1)

inventory = listdir(outdir)

if len(inventory) > 1:
    print("Error: Built more than one wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)

if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
    print("Error: Target was anyarch but built a none-any wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)
