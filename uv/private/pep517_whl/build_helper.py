#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from argparse import ArgumentParser
import json
import os
import platform as _platform
import shlex
import shutil
import sys
from os import chmod, defpath, listdir, makedirs, path, pathsep
from subprocess import CalledProcessError, check_call, check_output, STDOUT
from tempfile import TemporaryFile

from uv.private.pep517_whl.memory_monitor import run_with_memory_profile

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

_SETUPTOOLS_BACKENDS = (
    None,
    "setuptools.build_meta",
    "setuptools.build_meta:__legacy__",
)


# Configured compiler commands may contain paths relative to Bazel's execroot,
# while build backends run from the unpacked source tree. Each default wrapper
# embeds the complete command, with toolchain paths made absolute, so target,
# sysroot, and compiler-driver selection survive the cwd change.
_DEBUG_FLAG = "-fdebug-default-version=4"
_COMPILER_WRAPPER = """#!/usr/bin/env python3
import os
import sys

command = {command!r}
environment = {environment!r}
filtered_args = [
    arg
    for arg in command[1:] + sys.argv[1:]
    if arg != {debug_flag!r}
]
sysroot = {sysroot!r}
has_sysroot = any(
    arg in ("-isysroot", "--sysroot")
    or arg.startswith("-isysroot")
    or arg.startswith("--sysroot=")
    for arg in filtered_args
)
if sysroot and not has_sysroot:
    filtered_args = ["-isysroot", sysroot] + filtered_args
child_env = os.environ.copy()
child_env.update(environment)
# Preserve the configured command's driver identity. Some toolchains expose
# clang and clang++ as different entry points into one multicall binary.
os.execve(command[0], [command[0]] + filtered_args, child_env)
"""

_DEFAULT_COMPILER_COMMANDS = {
    "CC": ["cc"],
    "CXX": ["c++"],
}


def _darwin_sysroot():
    """Return the macOS SDK path, or None if unavailable."""
    if _platform.system() != "Darwin":
        return None
    try:
        return check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    except Exception:
        return None


def _absolutize_input_roots(value, action_root, input_roots):
    """Relocate every relative toolchain-root token through a cwd change."""
    result = []
    position = 0
    while position < len(value):
        matches = [
            (index, root)
            for root in input_roots
            if (index := value.find(root, position)) >= 0
        ]
        if not matches:
            result.append(value[position:])
            break
        root_index, root = min(matches, key=lambda match: (match[0], -len(match[1])))
        token_start = max(
            value.rfind(delimiter, position, root_index)
            for delimiter in " =,:;\"'"
        )
        suffix = value[root_index + len(root):]
        if "/" not in value[token_start + 1:root_index] and (
            not suffix or suffix[0] in "/:;, \"'"
        ):
            result.append(value[position:root_index])
            result.append(path.join(action_root, root))
            position = root_index + len(root)
        else:
            result.append(value[position:root_index + 1])
            position = root_index + 1
    return "".join(result)


def _compiler_command(env, key, default, action_root, input_roots):
    """Select an explicit or toolchain-provided compiler command."""
    current = env.get(key)
    command = shlex.split(current) if current else list(default)
    if not command:
        raise ValueError("{} compiler command is empty".format(key))

    command = [
        _absolutize_input_roots(argument, action_root, input_roots)
        for argument in command
    ]

    executable = command[0]
    if not path.isabs(executable):
        if path.dirname(executable):
            command[0] = path.join(action_root, executable)
        else:
            resolved = shutil.which(executable)
            if resolved is None:
                raise FileNotFoundError(
                    "compiler not found on PATH: {}".format(executable),
                )
            command[0] = resolved
    return command


def _visible_compiler_command(command, sysroot):
    command = [argument for argument in command if argument != _DEBUG_FLAG]
    has_sysroot = any(
        argument in ("-isysroot", "--sysroot")
        or argument.startswith("-isysroot")
        or argument.startswith("--sysroot=")
        for argument in command[1:]
    )
    if sysroot and not has_sysroot:
        command[1:1] = ["-isysroot", sysroot]
    return shlex.join(command)


def _make_compiler_wrapper(tmpdir, name, command, environment, sysroot):
    wrapper_dir = path.join(tmpdir, ".aspect_rules_py_compilers")
    wrapper = path.join(wrapper_dir, name)
    makedirs(path.dirname(wrapper), exist_ok=True)
    with open(wrapper, "w") as f:
        f.write(_COMPILER_WRAPPER.format(
            command=command,
            debug_flag=_DEBUG_FLAG,
            environment=environment,
            sysroot=sysroot,
        ))
    chmod(wrapper, 0o755)
    return wrapper


def _compiler_env(tmpdir, compiler_config, action_root):
    env = dict(os.environ)
    env["PATH"] = pathsep.join([
        path.dirname(sys.executable),
        env.get("PATH", defpath),
    ])
    env["TMP"] = tmpdir
    env["TEMP"] = tmpdir
    env["TEMPDIR"] = tmpdir

    default_commands = compiler_config.get("commands", {})
    default_environments = compiler_config.get("environments", {})
    input_roots = sorted(compiler_config.get("input_roots", ()), key=len, reverse=True)
    sysroot = _darwin_sysroot()
    compiler_commands = {}
    for key, name in [
        ("CC", "cc"),
        ("CXX", "c++"),
    ]:
        explicit = bool(env.get(key))
        command = _compiler_command(
            env,
            key,
            default_commands.get(key, _DEFAULT_COMPILER_COMMANDS[key]),
            action_root,
            input_roots,
        )
        if explicit:
            compiler_commands[key] = _visible_compiler_command(command, sysroot)
        else:
            compiler_commands[key] = _make_compiler_wrapper(
                tmpdir,
                name,
                command,
                {
                    env_name: _absolutize_input_roots(value, action_root, input_roots)
                    for env_name, value in default_environments.get(key, {}).items()
                },
                sysroot,
            )
        env[key] = compiler_commands[key]

    for key in ("LDSHARED", "LDCXXSHARED"):
        if not env.get(key):
            continue
        command = _compiler_command(
            env,
            key,
            [],
            action_root,
            input_roots,
        )
        env[key] = _visible_compiler_command(command, sysroot)

    if env.get("CPP"):
        command = _compiler_command(
            env,
            "CPP",
            [],
            action_root,
            input_roots,
        )
        env["CPP"] = _visible_compiler_command(command, sysroot)

    if not env.get("MPICC"):
        mpicc = shutil.which("mpicc", path=env["PATH"])
        if mpicc:
            env["MPICC"] = _make_compiler_wrapper(
                tmpdir, "mpicc", [mpicc], {}, sysroot
            )
    env.setdefault("AR", "ar")
    return env


def _load_text(maybe_file):
    if not path.exists(maybe_file):
        return ""

    with open(maybe_file, encoding="utf-8", errors="ignore") as f:
        return f.read()


def _load_pyproject_data(worktree):
    pyproject = path.join(worktree, "pyproject.toml")
    if not path.exists(pyproject):
        return None

    try:
        with open(pyproject, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return None


def _legacy_metadata_conflicts_with_pyproject(worktree):
    setup_py = path.join(worktree, "setup.py")
    pyproject_data = _load_pyproject_data(worktree)
    if not (pyproject_data and path.exists(setup_py)):
        return False

    build_backend = pyproject_data.get("build-system", {}).get("build-backend")
    if build_backend not in _SETUPTOOLS_BACKENDS:
        return False

    project = pyproject_data.get("project")
    if not project:
        return False

    dynamic = set(project.get("dynamic", []))
    legacy_metadata = _load_text(setup_py) + "\n" + _load_text(path.join(worktree, "setup.cfg"))

    return (
        ("dependencies" not in project and "dependencies" not in dynamic and "install_requires" in legacy_metadata) or
        (
            "optional-dependencies" not in project and
            "optional-dependencies" not in dynamic and
            "extras_require" in legacy_metadata
        )
    )

PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--compiler-config")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
opts, args = PARSER.parse_known_args()

action_root = path.abspath(os.curdir)
compiler_config = json.loads(opts.compiler_config) if opts.compiler_config else {}
tmp_root = path.abspath(opts.outdir) + ".tmp"
# Sandboxed/remote actions get a fresh root each run, so we don't expect a stale tmp_root to exist.
makedirs(tmp_root, exist_ok=False)

t = path.join(tmp_root, "worktree")

shutil.unpack_archive(opts.srcarchive, t)

# Annoyingly, unpack_archive creates a subdir in the target. Update t
# accordingly. Not worth the eng effort to prevent creating this dir.
t = path.join(t, listdir(t)[0])

if opts.patches:
    for patch_file in opts.patches:
        # Patched source trees must not include backups of mismatched hunks:
        # https://www.gnu.org/software/diffutils/manual/html_node/patch-Options.html
        check_call(
            [
                "patch",
                "--no-backup-if-mismatch",
                "-p{}".format(opts.patch_strip),
                "-i",
                path.abspath(patch_file),
            ],
            cwd=t,
        )


# Get a path to the outdir which will be valid after we cd
outdir = path.abspath(opts.outdir)

# Preserve configured compiler and linker commands through the cwd change into
# the worktree.
build_env = _compiler_env(tmp_root, compiler_config, action_root)

if _legacy_metadata_conflicts_with_pyproject(t):
    print(
        "Warning: falling back to setup.py because pyproject.toml omits dynamic dependency metadata "
        "that setuptools still reads from setup.py/setup.cfg.",
        file=sys.stderr,
    )
    cmd = [
        sys.executable,
        path.realpath(path.join(t, "setup.py")),
        "bdist_wheel",
        "--dist-dir",
        outdir,
    ]
elif path.exists(path.join(t, "pyproject.toml")) or path.exists(path.join(t, "setup.py")):
    # Always use `python -m build` (PEP 517 frontend). For setup.py-only
    # packages without a pyproject.toml, build creates a minimal PEP 517
    # shim automatically. --no-isolation ensures it uses the deps we've
    # already provided in the build venv rather than trying to pip-install.
    # Routing legacy setup_requires=… packages (e.g. googlemaps 4.10.0)
    # through setup.py directly triggers setuptools' deprecated
    # fetch_build_eggs path, which crashes on modern packaging.
    #
    # --skip-dependency-check disables `build`'s validation of
    # `[build-system].requires` against the active venv. The
    # validation is redundant under --no-isolation (we already
    # commit to managing the venv) and rejects packages that pile
    # unrelated dev tooling into `requires` — cdifflib 1.2.9 lists
    # pytest/ruff/twine there, none of which are actually needed
    # to compile its C extension.
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
        run_with_memory_profile(
            cmd,
            cwd=t,
            env=build_env,
            stdout=build_log,
            wheel=path.basename(opts.srcarchive),
        )
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
