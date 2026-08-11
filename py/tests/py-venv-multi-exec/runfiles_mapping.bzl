"""Runfiles mapping fixture for pyc_only filtering tests."""

def _runfiles_mapping_impl(ctx):
    return [DefaultInfo(runfiles = ctx.runfiles(
        symlinks = {"mapped.py": ctx.file.src},
        root_symlinks = {"root-mapped.py": ctx.file.src},
    ))]

runfiles_mapping = rule(
    implementation = _runfiles_mapping_impl,
    attrs = {"src": attr.label(allow_single_file = True, mandatory = True)},
)
