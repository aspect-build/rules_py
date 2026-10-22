# Unfortunately there is no way to stop pex from writing to a PEX_ROOT during build.
# Closest thing seems to be creating a tmp folder and deleting it after.
# pex cli does the same here;
# https://github.com/pex-tool/pex/blob/252459bdd879fc1e3446a6221571875d46fad1bd/pex/commands/command.py#L362-L382
import os
import re
import warnings

# Importing pex probes for musl libc by running `ldd`, which is not on an action's
# PATH, so it warns on every build and assumes glibc. Building a PEX does not
# depend on the answer.
warnings.filterwarnings("ignore", message="Failed to detect if this interpreter is running under musl libc")

from pex.common import safe_mkdtemp, safe_rmtree
TMP_PEX_ROOT=safe_mkdtemp()
os.environ["PEX_ROOT"] = TMP_PEX_ROOT

import sys
from pex.pex_builder import Check,PEXBuilder
from pex.inherit_path import InheritPath
from pex.interpreter_constraints import InterpreterConstraints
from pex.layout import Layout
from pex.dist_metadata import Distribution
from pex.installed_wheel import InstalledWheel
from pex.wheel import Wheel, WheelMetadataLoadError
from argparse import Action, ArgumentError, ArgumentParser, Namespace

class InjectEnvAction(Action):
    def __call__(
        self,
        parser: ArgumentParser,
        namespace: Namespace,
        values: object,
        option_string: str | None = None,
    ) -> None:
        assert isinstance(values, str)
        components = values.split("=", 1)
        if len(components) != 2:
            raise ArgumentError(
                self,
                "Environment variable values must be of the form `name=value`. "
                "Given: {value}".format(value=values),
            )
        self.default.append(tuple(components))


class InheritPathAction(Action):
    def __call__(
        self,
        parser: ArgumentParser,
        namespace: Namespace,
        values: object,
        option_string: str | None = None,
    ) -> None:
        assert isinstance(values, str)
        setattr(namespace, self.dest, InheritPath.for_value(values))


parser = ArgumentParser(fromfile_prefix_chars='@')

parser.add_argument(
    "-o",
    "--output-file",
    dest="pex_name",
    required=True,
    help="The name of the generated .pex file.",
)

parser.add_argument(
    "--python-version-constraint",
    dest="constraints",
    default=[],
    action="append"
)

parser.add_argument(
    "--python-shebang",
    dest="python_shebang",
    default=None,
    required=True,
    help="The exact shebang (#!...) line to add at the top of the PEX file minus the "
    "#!. This overrides the default behavior, which picks an environment Python "
    "interpreter compatible with the one used to build the PEX file.",
)

parser.add_argument(
    "--entrypoint",
    dest="entrypoint",
    required=True,
    metavar="RLOCATION",
    help="Runfiles path of the Python entry-point script (e.g. _main/py/tests/main.py).",
)

parser.add_argument(
    "--dependency",
    dest="dependencies",
    default=[],
    action="append",
)

parser.add_argument(
    "--source",
    dest="sources",
    default=[],
    action="append",
)

parser.add_argument(
    "--inject-env",
    dest="inject_env",
    default=[],
    action=InjectEnvAction,
)

parser.add_argument(
    "--sys-path",
    dest="sys_path",
    default=[],
    action="append",
)

parser.add_argument(
    "--inherit-path",
    dest="inherit_path",
    default=None,
    action=InheritPathAction,
)

parser.add_argument("--scie", dest="scie", default=None, choices=["eager"])
parser.add_argument("--scie-pbs-archive", dest="scie_pbs_archive", default=None)
parser.add_argument("--scie-science", dest="scie_science", default=None)
parser.add_argument("--scie-jump", dest="scie_jump", default=None)
parser.add_argument("--scie-output-file", dest="scie_output_file", default=None)

options = parser.parse_args(args = sys.argv[1:])

# pex stamps each zip entry with the mode of the file it zips, but Bazel does not
# track file modes: an action's key covers its inputs' contents only, remote
# execution hands the action every input marked executable, and a local build sees
# a source file with whatever mode the checkout's umask gave it. The PEX's bytes
# would then depend on which executor built it. Give every entry one mode instead,
# executable so that no file needing the bit can lose it. pex >= 2.60 already
# normalizes the other bits, but keys the executable bit on the file on disk.
from pex.common import ZipFileType

def _fixed_zip_file_type(path: str) -> ZipFileType.Value:
    return ZipFileType.DIRECTORY if os.path.isdir(path) else ZipFileType.EXECUTABLE

setattr(ZipFileType, "from_path", staticmethod(_fixed_zip_file_type))


pex_builder = PEXBuilder(
    # Build the PEX artifact using the current interpreter; we know it works in cfg=exec
    # because that's how we're already running. Interpreters inferred by other means might
    # not work in cross-builds.
    interpreter=None,
)


executable = options.entrypoint
executable_was_set = False


pex_builder.set_shebang(options.python_shebang)

pex_info = pex_builder.info
pex_info.inject_env = options.inject_env
pex_info.interpreter_constraints = InterpreterConstraints.parse(*options.constraints)
if options.inherit_path is not None:
    pex_info.inherit_path = options.inherit_path

for dep in options.dependencies:
    dist = Distribution.load(dep)

    # The PEX's boot code reads each `.deps/` entry's project and version from its
    # name, which must therefore be the wheel's file name. A wheel without the
    # WHEEL file PEP 427 requires, as some hand-built ones are, is taken to be pure
    # Python for any Python 3.
    try:
        wheel = Wheel.from_distribution(dist)
        key = wheel.wheel_file_name
        metadata_dir = wheel.metadata_dir
        root_is_purelib = wheel.metadata.root_is_purelib
    except WheelMetadataLoadError:
        key = "%s-%s-py3-none-any.whl" % (re.sub(r"[-_.]+", "_", dist.project_name), dist.version.replace("-", "_"))
        metadata_dir = os.path.dirname(dist.metadata.files.metadata.rel_path)
        root_is_purelib = True
    dist_hash = pex_builder._add_dist(
        path= dist.location,
        dist_name = key
    )

    # The boot code also loads each entry as an installed wheel, from the layout
    # file pex writes when it installs one itself. A site-packages tree is that
    # wheel installed with everything at its root, as pex lays out a chroot.
    layout_relpath = os.path.join(pex_info.internal_cache, key, ".layout.json")
    InstalledWheel.save(
        prefix_dir=os.path.dirname(os.path.join(pex_builder.path(), layout_relpath)),
        stash_dir=".prefix",
        record_relpath=os.path.join(metadata_dir, "RECORD"),
        root_is_purelib=root_is_purelib,
        sys_path_entries=(".",),
    )
    pex_builder._chroot.touch(layout_relpath, label=key)
    pex_info.add_distribution(key, dist_hash)
    pex_builder.add_requirement(dist.as_requirement())

for source in options.sources:
    src, dest = source.split("=", 1)

    # if destination path matches the entrypoint script, then also set the executable.
    if dest == executable:
        pex_builder.set_executable(src)
        executable_was_set = True

    pex_builder.add_source(
        src,
        dest
    )

if not executable_was_set:
    print("Have not seen the source that corresponds to %s in the runfiles. Please file an issue." % executable)
    sys.exit(1)

pex_builder.freeze(bytecode_compile=False)

# Point RUNFILES_DIR and the binary's import paths at the directory the PEX runs
# from, once pex's boot code has installed it there. The preamble cannot do this:
# it runs before the boot code resolves that directory. freeze() writes the boot
# code into the chroot, so splice the setup in there before build() zips it.
BOOT_ANCHOR = "    from pex.globals import Globals\n"
runfiles_setup = ["    os.environ['RUNFILES_DIR'] = entry_point\n"]
for path in options.sys_path:
    runfiles_setup.append("    sys.path.append(os.path.abspath(os.path.join(entry_point, %r)))\n" % path)

for boot_file in ("__main__.py", os.path.join("__pex__", "__init__.py")):
    boot_path = os.path.join(pex_builder.path(), boot_file)
    with open(boot_path) as fp:
        boot = fp.read()
    # Catches a pex upgrade that moves the boot code this splices into.
    assert boot.count(BOOT_ANCHOR) == 1, "Check the boot code splice in %s." % boot_file
    with open(boot_path, "w") as fp:
        fp.write(boot.replace(BOOT_ANCHOR, "".join(runfiles_setup) + BOOT_ANCHOR))

pex_builder.build(
    options.pex_name,
    deterministic=True,
    layout=Layout.ZIPAPP,
    check=Check.WARN,
)


if options.scie:
    import hashlib
    import json
    import shlex
    import shutil
    from pex import scie
    from pex.sysconfig import SysPlatform
    from pex.targets import Targets

    # python-build-standalone names its archives
    # cpython-<version>+<release>-<target triple>-<flavor>.<extension>.
    archive_name = os.path.basename(options.scie_pbs_archive)
    match = re.match(
        r"^cpython-(?P<version>\d+\.\d+\.\d+)\+(?P<release>\d{8})-(?P<triple>.+)-(?P<flavor>install_only(?:_stripped)?)\.(?P<extension>tar\.(?:gz|zst))$",
        archive_name,
    )
    if match is None:
        sys.exit("A scie needs an install_only or install_only_stripped python-build-standalone archive, not %s." % archive_name)

    triple = match.group("triple")
    platforms_by_triple = {
        "aarch64-apple-darwin": SysPlatform.MACOS_AARCH64,
        "aarch64-unknown-linux-gnu": SysPlatform.LINUX_AARCH64,
        "aarch64-unknown-linux-musl": SysPlatform.MUSL_LINUX_AARCH64,
        "x86_64-apple-darwin": SysPlatform.MACOS_X86_64,
        "x86_64-unknown-linux-gnu": SysPlatform.LINUX_X86_64,
        "x86_64-unknown-linux-musl": SysPlatform.MUSL_LINUX_X86_64,
    }
    scie_platform = platforms_by_triple.get(triple)
    # science assembles a scie with a scie-jump for the platform it runs on, which
    # it otherwise downloads; it takes ours only as the scie's own scie-jump too.
    if scie_platform is None or scie_platform.os_arch != SysPlatform.CURRENT.os_arch:
        sys.exit("A scie for %s can only be built on that platform, not on %s." % (triple, SysPlatform.CURRENT.os_arch))

    # science fetches the interpreter from a python-build-standalone mirror, so
    # serve it one holding just this archive.
    mirror = safe_mkdtemp()
    release_dir = os.path.join(mirror, "providers", "PythonBuildStandalone", "download", match.group("release"))
    os.makedirs(release_dir)
    os.symlink(os.path.abspath(options.scie_pbs_archive), os.path.join(release_dir, archive_name))
    digest = hashlib.sha256()
    with open(options.scie_pbs_archive, "rb") as fp:
        while chunk := fp.read(1024 * 1024):
            digest.update(chunk)
    index = {
        "release": match.group("release"),
        "assets": [{
            "digest": {"fingerprint": digest.hexdigest(), "size": os.path.getsize(options.scie_pbs_archive)},
            "file_type": match.group("extension"),
            "name": archive_name,
            "rel_path": "download/%s/%s" % (match.group("release"), archive_name),
            "target_triple": triple,
            "version": match.group("version"),
        }],
    }
    with open(os.path.join(release_dir, "distributions-%s-%s.json" % (match.group("version"), match.group("flavor"))), "w") as fp:
        json.dump(index, fp)

    scie_parser = ArgumentParser()
    scie.register_options(scie_parser)
    scie_args = [
        "--scie", "eager",
        "--scie-only",
        "--scie-platform", scie_platform.value,
        "--scie-pbs-release", match.group("release"),
        "--scie-python-version", match.group("version"),
        "--scie-science-binary", os.path.abspath(options.scie_science),
        "--scie-assets-base-url", "file://" + os.path.abspath(mirror),
    ]
    if match.group("flavor") == "install_only_stripped":
        scie_args.append("--scie-pbs-stripped")
    scie_options = scie.extract_options(scie_parser.parse_args(scie_args))
    assert scie_options is not None
    # The scie is for this platform, whose interpreter is the default target.
    scie_configuration = scie_options.create_configuration(targets=Targets())

    # science is itself a scie, which unpacks under SCIE_BASE when it runs, and it
    # keeps temporary files in the user's cache directory. Both default under HOME,
    # which an action cannot write to.
    os.environ["SCIE_BASE"] = safe_mkdtemp()
    os.environ["HOME"] = os.environ["XDG_CACHE_HOME"] = safe_mkdtemp()
    if sys.platform.startswith("linux"):
        # On Linux science runs `ldd` on its interpreter to tell musl from glibc,
        # and an action has no PATH. Answer from the binary, as ldd would.
        ldd_dir = safe_mkdtemp()
        ldd = os.path.join(ldd_dir, "ldd")
        with open(ldd, "w") as fp:
            fp.write("#!/bin/sh\nexec %s -c 'import platform, sys; print(platform.libc_ver(sys.argv[1])[0] or \"musl\")' \"$1\"\n" % shlex.quote(sys.executable))
        os.chmod(ldd, 0o755)
        os.environ["PATH"] = os.pathsep.join(filter(None, (ldd_dir, os.environ.get("PATH"))))
    os.environ["SCIENCE_LIFT_BUILD_USE_JUMP"] = os.path.abspath(options.scie_jump)
    for scie_info in scie.build(scie_configuration, options.pex_name):
        if os.path.abspath(scie_info.file) != os.path.abspath(options.scie_output_file):
            shutil.move(scie_info.file, options.scie_output_file)

# Cleanup temporary pex root
safe_rmtree(TMP_PEX_ROOT)
