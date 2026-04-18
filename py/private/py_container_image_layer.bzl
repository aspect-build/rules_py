"""py_container_image_layer for creating container images from py_container_binary.

This macro creates optimized container image layers from a py_container_binary target.
Unlike py_image_layer, it works with pre-built virtualenvs and is optimized for
container images with proper layer caching.

Example:
```
load("@aspect_rules_py//py:defs.bzl", "py_container_binary", "py_container_image_layer")
load("@rules_oci//oci:defs.bzl", "oci_image")

py_container_binary(
    name = "my_app",
    srcs = ["main.py"],
)

oci_image(
    name = "my_image",
    tars = py_container_image_layer(
        name = "my_app_layers",
        binary = ":my_app",
    ),
)
```
"""

load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@tar.bzl//tar:mtree.bzl", "mtree_mutate", "mtree_spec")
load("@tar.bzl//tar:tar.bzl", "tar")

default_layer_groups = {
    # Pre-built venv layer - contains the entire virtualenv
    # This layer changes when dependencies change
    "venv": "\\.venv/",
    
    # Python interpreter layer
    "interpreter": "\\.runfiles/[^/]*python_?[0-9]+_[0-9]+(_[0-9]+)?_[a-z0-9_]+[_-](unknown|apple|pc)[_-][^/]*/",
    
    # Third-party packages in site-packages
    "packages": "\\.runfiles/.*/site-packages",
}

def _split_mtree_into_layer_groups(name, root, groups, group_names, **kwargs):
    mtree_begin_blocks = "\n".join([
        'print "#mtree" >> "$(RULEDIR)/%s.%s.manifest.spec";' % (name, gn)
        for gn in group_names
    ])

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

def py_container_image_layer(
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
    """Produce a separate tar output for each layer of a py_container_binary.

    This macro is optimized for py_container_binary targets which have a pre-built
    virtualenv. It creates layers that optimize for Docker caching:
    1. 'interpreter' layer - Python interpreter (rarely changes)
    2. 'packages' layer - Third-party packages (changes with dependencies)
    3. 'venv' layer - Pre-built virtualenv (changes with dependencies)
    4. 'default' layer - Application code (changes frequently)

    Args:
        name: base name for targets
        binary: a py_container_binary target
        root: Path to where the layers should be rooted. Default is '/'.
        layer_groups: Additional layer groups to create.
        compress: Compression algorithm to use. Default is gzip.
        compute_unused_inputs: Whether to compute unused inputs. Default is 1.
        platform: The platform to use for the transition.
        owner: An owner uid for the uncompressed files.
        group: A group uid for the uncompressed files.
        tar_args: Additional arguments to pass to the tar rule.
        **kwargs: attribute that apply to all targets expanded by the macro

    Returns:
        A list of labels for each layer.
    """
    if root != None and not root.startswith("/"):
        fail("root path must start with '/' but got '{root}', expected '/{root}'".format(root = root))

    # Produce the manifest for a tar file of our binary
    manifest_name = name + ".manifest"
    if owner:
        mtree_spec(
            name = manifest_name + ".preprocessed",
            srcs = [binary],
            **kwargs
        )
        mtree_mutate(
            name = manifest_name,
            mtree = name + ".manifest.preprocessed",
            owner = owner,
            group = group,
        )
    else:
        mtree_spec(
            name = manifest_name,
            srcs = [binary],
            **kwargs
        )

    # Merge user-provided layer groups with defaults
    groups = dict(default_layer_groups)
    groups.update(layer_groups)
    group_names = groups.keys() + ["default"]

    _split_mtree_into_layer_groups(name, root, groups, group_names, **kwargs)

    # Create layers using the tar rule
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
