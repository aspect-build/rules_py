"""py_image_layer macro for creating multiple layers from a py_binary

>> [!WARNING]
>> This macro is EXPERIMENTAL and is not subject to our SemVer guarantees.

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
        py_binary = ":my_app_bin",
        layer_groups = {
            "torch": "pip_deps_torch.*",
            "numpy": "pip_deps_numpy.*",
        }
    )
)
```
"""

load("@aspect_bazel_lib//lib:tar.bzl", "mtree_spec", "tar")

default_layer_groups = {
    # match *only* external pip like repositories that contain the string "site-packages"
    "packages": "\\.runfiles/.*/site-packages",
    # match *only* external repositories that begins with the string "python"
    # e.g. this will match
    #   `/hello_world/hello_world_bin.runfiles/rules_python~0.21.0~python~python3_9_aarch64-unknown-linux-gnu/bin/python3`
    # but not match
    #   `/hello_world/hello_world_bin.runfiles/_main/python_app`
    "interpreter": "\\.runfiles/python.*-.*/",
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
    if ($$1 ~ ".whl") {
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
        name = "_{}_manifests".format(name),
        srcs = [name + ".manifest"],
        outs = [
            "{}.{}.manifest.spec".format(name, group_name)
            for group_name in group_names
        ],
        cmd = cmd,
        **kwargs
    )


def py_image_layer(name, py_binary, root = None, layer_groups = {}, compress = "gzip", tar_args = ["--options", "gzip:!timestamp"], **kwargs):
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
        "packages": "\\.runfiles/pip_deps.*", # contains third-party deps
        "interpreter": "\\.runfiles/python.*-.*/", # contains the python interpreter
    }
    ```

    Args:
        name: base name for targets
        py_binary: a py_binary target
        root: Path to where the layers should be rooted. If not specified, the layers will be rooted at the workspace root.
        layer_groups: Additional layer groups to create. They are used to group files into layers based on their path. In the form of: ```{"<name>": "regex_to_match_against_file_paths"}```
        compress: Compression algorithm to use. Default is gzip. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule
        tar_args: Additional arguments to pass to the tar rule. Default is `["--options", "gzip:!timestamp"]`. See: https://github.com/bazel-contrib/bazel-lib/blob/main/docs/tar.md#tar_rule
        **kwargs: attribute that apply to all targets expanded by the macro

    Returns:
        A list of labels for each layer.
    """
    if root != None and not root.startswith("/"):
        fail("root path must start with '/' but got '{root}', expected '/{root}'".format(root = root))

    # Produce the manifest for a tar file of our py_binary, but don't tar it up yet, so we can split
    # into fine-grained layers for better pull, push and remote cache performance.
    mtree_spec(
        name = name + ".manifest",
        srcs = [py_binary],
        **kwargs
    )

    groups = dict(**layer_groups)
    group_names = groups.keys() + ["default"]

    _split_mtree_into_layer_groups(name, root, groups, group_names, **kwargs)

    # Finally create layers using the tar rule
    result = []
    for group_name in group_names:
        tar_target = "_{}_{}".format(name, group_name)
        tar(
            name = tar_target,
            srcs = [py_binary],
            mtree = "{}.{}.manifest.spec".format(name, group_name),
            compress = compress,
            args = tar_args,
            **kwargs
        )
        result.append(tar_target)

    return result
