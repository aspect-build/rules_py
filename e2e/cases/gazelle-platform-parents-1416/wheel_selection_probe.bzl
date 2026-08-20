"""Analysis-time probe over a hub's `gazelle_index_whls` filegroup.

Writes one `distribution: platform-class` line per resolved wheel, so a
snapshot can pin *which kind* of wheel the configuration selected (e.g.
`cffi: linux_x86_64`) without materializing the wheels and without coupling
the golden to exact versions or manylinux tag spellings, both of which churn
on lock updates. Classification happens at analysis time from basenames, so
the probe never triggers sdist builds for the transitioned platform.
"""

def _classify_platform_tag(basename):
    tag = basename[:-len(".whl")].split("-")[-1]
    if tag == "any":
        return "any"
    os = "unknown-os"
    if "linux" in tag:
        os = "linux"
    elif "macosx" in tag:
        os = "macosx"
    elif "win" in tag:
        os = "windows"
    cpu = "unknown-cpu"
    if "universal2" in tag:
        cpu = "universal2"
    elif "x86_64" in tag or "amd64" in tag:
        cpu = "x86_64"
    elif "aarch64" in tag or "arm64" in tag:
        cpu = "aarch64"
    return "{}_{}".format(os, cpu)

def _wheel_selection_probe_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    lines = []
    for f in ctx.attr.src[DefaultInfo].files.to_list():
        if f.basename.endswith(".whl"):
            dist = f.basename.split("-")[0].lower()
            lines.append("{}: {}".format(dist, _classify_platform_tag(f.basename)))
        elif f.basename == "whl":
            lines.append("{}: sdist-fallback".format(f.owner.repo_name))
    ctx.actions.write(out, "\n".join(sorted(lines)) + "\n")
    return [DefaultInfo(files = depset([out]))]

wheel_selection_probe = rule(
    implementation = _wheel_selection_probe_impl,
    attrs = {
        "src": attr.label(providers = [DefaultInfo]),
    },
)
