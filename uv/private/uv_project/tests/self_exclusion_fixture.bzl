"""Generate the real build-dependency graph for the B -> A -> C fixture."""

# Use the production sdist inspector's PBS interpreter, not a host Python.
# buildifier: disable=bzl-visibility
load("//py/private/interpreter:resolve.bzl", "resolve_host_interpreter_label")
load("//uv/private/sdist_build:repository.bzl", "sdist_build")
load("//uv/private/sdist_configure:defs.bzl", "DEFAULT_CONFIGURE_SCRIPT")
load("//uv/private/uv_project:repository.bzl", "uv_project")

def _source_impl(repository_ctx):
    repository_ctx.watch(repository_ctx.attr.interpreter)
    for src in repository_ctx.attr.srcs:
        repository_ctx.watch(src)
    result = repository_ctx.execute(
        [
            str(repository_ctx.path(repository_ctx.attr.interpreter)),
            "-I",
            "-c",
            """\
import gzip
import io
from pathlib import Path
import sys
import tarfile

with open(sys.argv[1], "wb") as output:
    with gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for filename in sorted(sys.argv[2:]):
                source = Path(filename)
                content = source.read_bytes()
                member = tarfile.TarInfo("self_exclusion_a-0.0.1/" + source.name)
                member.size = len(content)
                member.mode = 0o644
                member.mtime = 0
                archive.addfile(member, io.BytesIO(content))
""",
            str(repository_ctx.path("source.tar.gz")),
        ] + [str(repository_ctx.path(src)) for src in repository_ctx.attr.srcs],
        timeout = 30,
    )
    if result.return_code:
        fail("Could not create the self-exclusion fixture archive: " + result.stderr)
    repository_ctx.file("BUILD.bazel", 'exports_files(["source.tar.gz"], visibility = ["//visibility:public"])')
    return repository_ctx.repo_metadata(reproducible = True)

_source = repository_rule(
    implementation = _source_impl,
    attrs = {
        "interpreter": attr.label(mandatory = True),
        "srcs": attr.label_list(allow_files = True, mandatory = True),
    },
)

def _self_exclusion_fixture_impl(module_ctx):
    interpreter = resolve_host_interpreter_label(module_ctx)
    if interpreter == None:
        fail("The self-exclusion fixture requires a supported host PBS interpreter.")
    _source(
        name = "uv_project_self_exclusion_source",
        interpreter = interpreter,
        srcs = [
            Label(":self_exclusion_backend/backend.py"),
            Label(":self_exclusion_backend/pyproject.toml"),
        ],
    )
    installs = {
        "a": str(Label(":self_exclusion_a_install")),
        "b": str(Label(":self_exclusion_b_install")),
        "c": str(Label(":self_exclusion_c_install")),
    }
    uv_project(
        name = "uv_project_self_exclusion_test",
        available_deps_json = json.encode({
            name: "@uv_project_self_exclusion_test//private/build_deps:" + name
            for name in installs
        }),
        build_deps_json = json.encode({
            "packages": {
                name: [install, "//private/build_deps/sccs:" + name]
                for name, install in installs.items()
            },
            "scc_graph": {
                "a": {
                    installs["a"]: {"": 1},
                    "//private/build_deps/sccs:c": {"python_version >= '3.10'": 1},
                },
                "b": {
                    installs["b"]: {"": 1},
                    "//private/build_deps/sccs:a": {"": 1},
                },
                "c": {installs["c"]: {"": 1}},
            },
            "sdists": {"a": installs["a"]},
        }),
        dep_to_scc = "{}",
        scc_deps = "{}",
        scc_graph = "{}",
    )
    sdist_build(
        name = "uv_project_self_exclusion_sdist",
        src = "@uv_project_self_exclusion_source//:source.tar.gz",
        available_deps_file = "@uv_project_self_exclusion_test//:available_deps.json",
        build_deps_without_self_file = "@uv_project_self_exclusion_test//:build_deps_without_self/a.json",
        configure_command = [
            "$(location {})".format(interpreter),
            "$(location {})".format(DEFAULT_CONFIGURE_SCRIPT),
        ],
        deps = [Label("@pypi//build")],
        version = "0.0.1",
    )
    return module_ctx.extension_metadata(reproducible = True)

self_exclusion_fixture = module_extension(implementation = _self_exclusion_fixture_impl)
