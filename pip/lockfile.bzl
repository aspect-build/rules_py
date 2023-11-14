load("//pip/private:toml.bzl", "parse_pdm_lockfile")

def _format_package(p):
    files = ["""            "{}": "{}",""".format(f["url"], f["hash"]) for f in p["files"]]
    dependencies = ["""            "{}",""".format(d.replace('"', '\\"')) for d in p["dependencies"]]

    return """\
    # {}
    multiarch_wheel(
        name = "{}",
        version = "{}",
        files = {{
{}
        }},
        dependencies = [
{}
        ],
    )
""".format(
    p["summary"],
    p["name"],
    p["version"],
    "\n".join(files),
    "\n".join(dependencies),
)

def _pip_translate_lock_impl(rctx):
    packages_content = [_format_package(p) for p in parse_pdm_lockfile(rctx.read(rctx.path(rctx.attr.pdm_lock)))]
    rctx.file("BUILD", "")
    rctx.file("packages.bzl", "\"Generated from {}\"\n\ndef packages():\n{}".format(rctx.attr.pdm_lock, "\n".join(packages_content)))
    

pip_translate_lock = repository_rule(
    implementation = _pip_translate_lock_impl,
    attrs = {
        "pdm_lock": attr.label(),
    }
)

