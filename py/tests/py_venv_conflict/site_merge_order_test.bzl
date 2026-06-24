"""End-to-end coverage for regular-package physical merge order."""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py:defs.bzl", "py_test")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _wheel_set_impl(ctx):
    py_runtime = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    major = py_runtime.interpreter_version_info.major
    minor = py_runtime.interpreter_version_info.minor
    install_trees = []
    site_packages_paths = []
    wheels = []

    # `final` also claims the earlier `other` bucket. A global claimant map
    # therefore moves it ahead of the regular-package contributors, while the
    # canonical wheel sequence below keeps it last.
    for kind in ["other", "regular", "graft", "final"]:
        install_tree = ctx.actions.declare_directory("{}.install".format(kind))
        if kind == "other":
            command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/other"
printf 'VALUE = %s\n' "$4" > "$site/other/from_other.py"
"""
            top_levels = ("other",)
            namespace_entries = ("other/from_other.py",)
            namespace_dirs = ()
            regular_roots = ()
        elif kind == "regular":
            command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/mixed/root"
printf '' > "$site/mixed/root/__init__.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/root/collision.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/sibling.py"
"""
            top_levels = ("mixed",)
            namespace_entries = (
                "mixed/root/__init__.py",
                "mixed/root/collision.py",
                "mixed/sibling.py",
            )
            namespace_dirs = ()
            regular_roots = ("mixed/root",)
        elif kind == "graft":
            command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/mixed/root"
printf 'VALUE = %s\n' "$4" > "$site/mixed/root/collision.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/root/graft_unique.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/sibling.py"
"""
            top_levels = ("mixed",)
            namespace_entries = (
                "mixed/root/collision.py",
                "mixed/root/graft_unique.py",
                "mixed/sibling.py",
            )
            namespace_dirs = ("mixed/root",)
            regular_roots = ()
        else:
            command = """
set -eu
site="$1/lib/python$2.$3/site-packages"
mkdir -p "$site/mixed/root" "$site/other"
printf 'VALUE = %s\n' "$4" > "$site/mixed/root/collision.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/root/final_unique.py"
printf 'VALUE = %s\n' "$4" > "$site/mixed/sibling.py"
printf 'VALUE = %s\n' "$4" > "$site/other/from_final.py"
"""
            top_levels = ("mixed", "other")
            namespace_entries = (
                "mixed/root/collision.py",
                "mixed/root/final_unique.py",
                "mixed/sibling.py",
                "other/from_final.py",
            )
            namespace_dirs = ("mixed/root",)
            regular_roots = ()

        ctx.actions.run_shell(
            outputs = [install_tree],
            command = command,
            arguments = [
                install_tree.path,
                str(major),
                str(minor),
                json.encode(kind),
            ],
        )
        site_packages = "/".join([
            segment
            for segment in [
                ctx.label.repo_name or ctx.workspace_name,
                ctx.label.package,
                install_tree.basename,
            ]
            if segment
        ] + ["lib/python{}.{}/site-packages".format(major, minor)])
        install_trees.append(install_tree)
        site_packages_paths.append(site_packages)
        wheels.append(struct(
            top_levels = top_levels,
            layout_complete = True,
            namespace_top_levels = top_levels,
            namespace_entries = namespace_entries,
            namespace_dirs = namespace_dirs,
            regular_roots = regular_roots,
            site_packages_rfpath = site_packages,
            console_scripts = (),
            install_tree = install_tree,
        ))

    return [
        DefaultInfo(
            files = depset(install_trees),
            runfiles = ctx.runfiles(files = install_trees),
        ),
        PyInfo(
            imports = depset(site_packages_paths),
            transitive_sources = depset(install_trees),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        PyWheelsInfo(wheels = depset(direct = wheels, order = "postorder")),
    ]

_wheel_set = rule(
    implementation = _wheel_set_impl,
    toolchains = [PY_TOOLCHAIN],
)

def site_merge_order_test_suite():
    _wheel_set(
        name = "_site_merge_wheels",
        tags = ["manual"],
    )

    py_test(
        name = "site_merge_order_test",
        srcs = ["test_site_merge_order.py"],
        package_collisions = "ignore",
        deps = [":_site_merge_wheels"],
    )
