"""Runs [modify_mtree.awk](modify_mtree.awk) over an mtree to rewrite
symlink-shaped `type=file content=<path>` rows into `type=link` ones,
so bsdtar preserves them verbatim instead of following and inlining.

Shells out to the host `awk` (same approach rules_oci takes). The
script uses only POSIX awk features, so any host awk is fine.
"""

def _impl(ctx):
    out = ctx.outputs.out or ctx.actions.declare_file(ctx.label.name + ".spec")

    # Collect runfiles from srcs so the awk's `readlink` calls can
    # resolve `content=` paths against actual files in the sandbox.
    srcs_runfiles = [
        src[DefaultInfo].default_runfiles.files
        for src in ctx.attr.srcs
    ]

    assignments = []
    if ctx.attr.owner:
        assignments.append(("owner", ctx.attr.owner))
    if ctx.attr.group:
        assignments.append(("group", ctx.attr.group))

    args = ctx.actions.args()
    for (k, v) in assignments:
        args.add("-v")
        args.add("{}={}".format(k, v))
    args.add("-f", ctx.file.awk_script)
    args.add(ctx.file.mtree)

    ctx.actions.run_shell(
        # `LC_ALL=C` pins sort order for reproducibility independent of
        # the host's locale.
        command = 'awk "$@" | LC_ALL=C sort > "{out}"'.format(out = out.path),
        arguments = [args],
        inputs = depset(
            direct = [ctx.file.mtree, ctx.file.awk_script],
            transitive = srcs_runfiles,
        ),
        outputs = [out],
        mnemonic = "MtreePreserveSymlinks",
        progress_message = "Rewriting symlink entries in %{label}",
        use_default_shell_env = True,
    )

    return [DefaultInfo(files = depset([out]))]

mtree_preserve_symlinks = rule(
    implementation = _impl,
    attrs = {
        "mtree": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "mtree spec to rewrite.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Targets whose runfiles contain the files referenced by " +
                  "the mtree's `content=` paths. Needed so `readlink` " +
                  "resolves them in-sandbox.",
        ),
        "owner": attr.string(
            doc = "Numeric uid to stamp onto every entry.",
        ),
        "group": attr.string(
            doc = "Numeric gid to stamp onto every entry.",
        ),
        "awk_script": attr.label(
            allow_single_file = True,
            default = Label("//py/private:modify_mtree.awk"),
        ),
        "out": attr.output(),
    },
)
