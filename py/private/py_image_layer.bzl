"""py_image_layer macro for creating multiple layers from a py_binary

> [!WARNING]
> This macro is EXPERIMENTAL and is not subject to our SemVer guarantees.

A py_binary that uses `torch` and `numpy` can use the following layer groups:

```
load("@rules_oci//oci:defs.bzl", "oci_image")
load("@aspect_rules_py//py:defs.bzl", "py_image_layer", "py_binary")

py_binary(
    name = "my_app_bin",
    deps = [
        "@pip_deps//numpy",
        "@pip_deps//torch"
    ]
)

oci_image(
    tars = py_image_layer(
        name = "my_app",
        binary = ":my_app_bin",
        layer_groups = {
            "torch": "pip_deps_torch.*",
            "numpy": "pip_deps_numpy.*",
        }
    )
)
```
"""

load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@tar.bzl//tar:mtree.bzl", "mtree_mutate", "mtree_spec")
load("@tar.bzl//tar:tar.bzl", "tar")

# Resolve filesystem-level symlinks in mtree specs so that tars preserve them.
#
# mtree_spec records every file as type=file with a distinct content= path, even
# when files are symlinks to each other (e.g. python/python3 -> python3.13 in the
# Python toolchain). Without this, the tar contains multiple full copies.
#
# Detection uses two-step readlink in the Bazel sandbox:
#   1. readlink(sandbox_path) -> absolute cache path (always succeeds in sandbox)
#   2. readlink(cache_path) -> non-empty only if the real file is a symlink
# Only relative targets from step 2 are converted; absolute targets are cross-repo
# ctx.actions.symlink references that would break in containers.
#
# A Starlark rule (not a genrule) is required because genrules cannot access
# runfiles from srcs — only DefaultInfo.default_runfiles gives sandbox access.
#
# See: https://github.com/aspect-build/rules_py/issues/567

_RESOLVE_SYMLINKS_SCRIPT = """\
/type=file/ && /content=/ {
    match($0, /content=[^ ]+/); split(substr($0, RSTART, RLENGTH), p, "=")
    c = ""; cmd = "readlink \\\"" p[2] "\\\""; cmd | getline c; close(cmd)
    if (c != "") { t = ""; cmd2 = "readlink \\\"" c "\\\""; cmd2 | getline t; close(cmd2)
        if (t != "" && t !~ /^\\//) { sub(/type=file/, "type=link"); sub(/content=[^ ]+/, "link=" t) }
    }
} 1"""

def _resolve_symlinks_impl(ctx):
    out = ctx.outputs.out
    ctx.actions.run_shell(
        command = "awk '%s' %s > %s" % (_RESOLVE_SYMLINKS_SCRIPT, ctx.file.mtree.path, out.path),
        inputs = depset([ctx.file.mtree], transitive = [
            s[DefaultInfo].default_runfiles.files
            for s in ctx.attr.srcs
        ]),
        outputs = [out],
    )
    return [DefaultInfo(files = depset([out]))]

_resolve_symlinks = rule(
    doc = "Post-process an mtree spec to convert filesystem symlinks to type=link entries.",
    implementation = _resolve_symlinks_impl,
    attrs = {
        "mtree": attr.label(mandatory = True, allow_single_file = True),
        "srcs": attr.label_list(mandatory = True),
        "out": attr.output(mandatory = True),
    },
)

default_layer_groups = {
    # match *only* external repositories containing a Python interpreter,
    # by matching the interpreter repo naming convention:
    #   python[_]<major>_<minor>[_<patch>]_<arch>[-_]<vendor>[-_]<os>
    #
    # e.g. this will match
    #   `.runfiles/rules_python++python+python_3_9_x86_64-unknown-linux-gnu/bin/python3`
    #   `.runfiles/python_3_11_x86_64_unknown_linux_gnu/bin/python3`
    # but not match
    #   `.runfiles/rules_python++pip+pypi_313_argon2_cffi_bindings_cp36_abi3_manylinux_2_17_x86_64_.../`
    #   `.runfiles/_main/python_app`
    #
    # Note that due to dict key insertion order sensitivity, we want this group
    # to go first so that the entire interpreter including its bundled libraries
    # goes into the same layer.
    "interpreter": "\\\\.runfiles/[^/]*python_?[0-9]+_[0-9]+(_[0-9]+)?_[a-z0-9_]+[_-](unknown|apple|pc)[_-][^/]*/",
    # match *only* external pip like repositories that contain the string "site-packages"
    #
    # Note that this comes after the interpreter so that we won't bundle
    # interpreter embedded libraries (setuptools, pip, site) into the same
    # libraries layer.
    "packages": "\\\\.runfiles/.*/site-packages",
}

def _split_mtree_into_layer_groups(name, root, groups, group_names, **kwargs):
    mtree_begin_blocks = "\n".join([
        'print "#mtree" >> "$(RULEDIR)/%s.%s.manifest.spec";' % (name, gn)
        for gn in group_names
    ])

    # When an mtree entry matches a layer group, it will be moved into the mtree
    # for that group.
    ifs = "\n".join([
        """\
if ($$1 ~ "%s") {
    print $$0 >> "$(RULEDIR)/%s.%s.manifest.spec";
    next
}""" % (regex, name, gn)
        for (gn, regex) in groups.items()
    ])

    cmd = """\
awk < $< 'BEGIN {
    %s
}
{
    # Exclude .whl files from container images
    if ($$1 ~ "\\.whl$$") {
        next
    }
    # Move everything under the specified root
    sub(/^/, ".%s")
    # Match by regexes and write to the destination.
    %s
    # Every line that did not match the layer groups will go into the default layer.
    print $$0 >> "$(RULEDIR)/%s.default.manifest.spec"
}'
""" % (mtree_begin_blocks, root, ifs, name)

    native.genrule(
        name = "{}_manifests".format(name),
        srcs = [name + ".manifest"],
        outs = [
            "{}.{}.manifest.spec".format(name, group_name)
            for group_name in group_names
        ],
        cmd = cmd,
        **kwargs
    )

def py_image_layer(
        name,
        binary,
        root = "/",
        layer_groups = {},
        compress = "gzip",
        tar_args = [],
        compute_unused_inputs = 1,
        platform = None,
        owner = None,
        group = None,
        **kwargs):
    """Produce a separate tar output for each layer of a python app

    > Requires `awk` to be installed on the host machine/rbe runner.

    For better performance, it is recommended to split the output of a py_binary into multiple layers.
    This can be done by grouping files into layers based on their path by using the `layer_groups` attribute.

    The matching order for layer groups is as follows:
        1. `layer_groups` are checked first.
        2. If no match is found for `layer_groups`, the `default layer groups` are checked.
        3. Any remaining files are placed into the default layer.

    The default layer groups are:
    ```
    {
        "packages": "\\.runfiles/.*/site-packages", # contains third-party deps
        "interpreter": "\\.runfiles/..python_<ver>_<arch>[-_]<vendor>[-_]<os>.../", # contains the python interpreter
    }
    ```

    Args:
        name: base name for targets
        binary: a py_binary target
        root: Path to where the layers should be rooted. If not specified, the layers will be rooted at the workspace root.
        layer_groups: Additional layer groups to create. They are used to group files into layers based on their path. In the form of: ```{"<name>": "regex_to_match_against_file_paths"}```
        compress: Compression algorithm to use. Default is gzip. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule-compress
        compute_unused_inputs: Whether to compute unused inputs. Default is 1. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule-compute_unused_inputs
        platform: The platform to use for the transition. Default is None. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/transitions.md#platform_transition_binary-target_platform
        owner: An owner uid for the uncompressed files. See mtree_mutate: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#mutating-the-tar-contents
        group: A group uid for the uncompressed files. See mtree_mutate: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#mutating-the-tar-contents
        tar_args: Additional arguments to pass to the tar rule. Default is `[]`. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule-args
        **kwargs: attribute that apply to all targets expanded by the macro

    Returns:
        A list of labels for each layer.
    """
    if root != None and not root.startswith("/"):
        fail("root path must start with '/' but got '{root}', expected '/{root}'".format(root = root))

    # Produce the manifest for a tar file of our py_binary, but don't tar it up yet, so we can split
    # into fine-grained layers for better pull, push and remote cache performance.
    manifest_name = name + ".manifest"
    mtree_spec(
        name = manifest_name + ".raw",
        srcs = [binary],
        **kwargs
    )
    _resolve_symlinks(
        name = manifest_name + ".symlinks_resolved",
        mtree = manifest_name + ".raw",
        srcs = [binary],
        out = manifest_name + ".symlinks_resolved.mtree",
    )
    if owner:
        mtree_mutate(
            name = manifest_name,
            mtree = manifest_name + ".symlinks_resolved",
            owner = owner,
            group = group,
        )
    else:
        native.filegroup(
            name = manifest_name,
            srcs = [manifest_name + ".symlinks_resolved"],
        )

    groups = dict(**layer_groups)
    groups = dict(groups, **default_layer_groups)
    group_names = groups.keys() + ["default"]

    _split_mtree_into_layer_groups(name, root, groups, group_names, **kwargs)

    # Finally create layers using the tar rule
    srcs = []
    for group_name in group_names:
        tar_target = "{}_{}".format(name, group_name)
        tar(
            name = tar_target,
            srcs = [binary],
            mtree = "{}.{}.manifest.spec".format(name, group_name),
            compress = compress,
            compute_unused_inputs = compute_unused_inputs,
            args = tar_args,
            **kwargs
        )
        srcs.append(tar_target)

    if platform:
        platform_transition_filegroup(
            name = name,
            srcs = srcs,
            target_platform = platform,
            **kwargs
        )
    else:
        native.filegroup(
            name = name,
            srcs = srcs,
            **kwargs
        )

    return srcs
