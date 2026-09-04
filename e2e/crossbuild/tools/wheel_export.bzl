"""Export cross-built wheels for verification on native hardware.

Replaces the OCI-image exec verification with a lighter wheel-only flow:
CI builds wheels for the opposite architecture on each Linux runner, uploads
them as tarballs, and the native runner of that architecture extracts each
tarball, installs the wheel with pip, and runs the case's standalone Python
test.
"""

load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")

def pycross_wheel_export(name, wheel, main, amd64_platform, arm64_platform):
    """Declares per-arch bundle targets for one cross case.

    Produces "<name>_amd64_bundle" and "<name>_arm64_bundle" targets whose
    output is a "<name>_<arch>.tar.gz" tarball under bazel-bin/<package>.
    The tarball contains the cross-built wheel renamed to a valid PEP 491
    filename (derived from the wheel's own dist-info metadata) plus the
    standalone test file. The wheel is built for the requested target platform
    via a transition, so an amd64 host can produce an arm64 wheel and vice
    versa.

    Args:
        name: prefix for the produced targets, e.g. "msgpack".
        wheel: label of the sdist-build wheel target to re-export
            (typically @sdist_build__<project>__<pkg>__<version>//:whl).
        main: the case's runtime test file, runnable with `python <main>`.
        amd64_platform: platform label for linux/amd64.
        arm64_platform: platform label for linux/arm64.
    """
    for arch, platform in (("amd64", amd64_platform), ("arm64", arm64_platform)):
        transitioned_name = "{}_{}_wheel_src".format(name, arch)
        platform_transition_filegroup(
            name = transitioned_name,
            srcs = [wheel],
            target_platform = platform,
        )

        native.genrule(
            name = "{}_{}_bundle".format(name, arch),
            srcs = [":" + transitioned_name, ":" + main],
            outs = ["{}_{}.tar.gz".format(name, arch)],
            cmd = """
                wheel=$$(find $(SRCS) -name '*.whl' | head -1)
                main=$(location :""" + main + """)
                python3 - "$$wheel" "$$main" "$(@D)" "$@" <<'PY'
import os, sys, tarfile, zipfile, shutil
wheel_path, main_path, out_dir, out_tar = sys.argv[1:]
with zipfile.ZipFile(wheel_path) as zf:
    names = zf.namelist()
    wheel_info_path = next(n for n in names if n.endswith(".dist-info/WHEEL"))
    meta_path = next(n for n in names if n.endswith(".dist-info/METADATA"))
    wheel_info = zf.read(wheel_info_path).decode("utf-8")
    meta = zf.read(meta_path).decode("utf-8")

def _value(text, prefix):
    for line in text.splitlines():
        if line.startswith(prefix):
            return line.split(":", 1)[1].strip()
    raise ValueError(prefix + " not found in wheel")

dist = _value(meta, "Name:").replace("-", "_")
version = _value(meta, "Version:")
tag = _value(wheel_info, "Tag:")
new_name = "{}-{}-{}.whl".format(dist, version, tag)

shutil.copy(wheel_path, os.path.join(out_dir, new_name))
main_name = os.path.basename(main_path)
shutil.copy(main_path, os.path.join(out_dir, main_name))

with tarfile.open(out_tar, "w:gz") as tar:
    tar.add(os.path.join(out_dir, new_name), arcname=new_name)
    tar.add(os.path.join(out_dir, main_name), arcname=main_name)
PY
            """,
        )
