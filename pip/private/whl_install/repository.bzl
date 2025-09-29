"""

Wheel installation repos are actually a bit tricky because this is where we go
from wheel files to a filegroup/py_library. That means we have to perform
platform wheel selection here as well as invoking the installation action to
produce a filegroup/TreeArtifact.

"""

load("//pip/private/constraints/platform:defs.bzl", "supported_platform")
load(":parse_whl_name.bzl", "parse_whl_name")

def format_arms(d):
    content = ["        \"{}\": \"{}\"".format(k, v) for k, v in d.items()]
    content = ",\n".join(content)
    return "{\n" + content + "\n    }"

def select_key(pair):
    triple, _ = pair
    python, platform, abi = triple
    py_major = int(python[2])
    py_minor = int(python[3:]) if python[3:] else 0

    # FIXME: It'd be WAY better if we could enforce a stronger order here
    platform = platform.split("_")
    if platform[0] in ["manylinux", "musllinux", "macosx"]:
        platform = (int(platform[1]), int(platform[2]))
    else:
        # Really case of windows; potential BSD issues?
        platform = (0, 0)

    return ((py_major, py_minor), platform, abi)

def sort_select_arms(arms):
    # {(python, platform, abi): target}
    pairs = list(arms.items())
    pairs = sorted(pairs, key=select_key, reverse=True)
    return {a: b for a, b in pairs}
    
def _whl_install_impl(repository_ctx):
    prebuilds = json.decode(repository_ctx.attr.prebuilds)
    # Prebuilds is a mapping from whl file name to repo labels which contain
    # that file. We need to take these wheel files and parse out compatability.
    #
    # This is complicated by Starlark as with Python not treating lists as
    # values, so we have to go to strings of JSON in order to get value
    # semantics which is frustrating.

    # The strategy here is to roll through the wheels,
    configuration_set = {}
    select_arms = {}
    content = [
        "load(\"@aspect_rules_py//pip/private/whl_install:rule.bzl\", \"whl_install\")",
        "load(\"@aspect_rules_py//pip/private/whl_install:defs.bzl\", \"select_chain\")",
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    for whl, target in prebuilds.items():
        parsed = parse_whl_name(whl)

        # FIXME: Make it impossible to generate absurd combinations such as
        # cp212-none-cp312 with unsatisfiable version specs.
        for python_tag in parsed.python_tags:
            for platform_tag in parsed.platform_tags:
                # Escape hatch for ignoring weird unsupported platforms
                if not supported_platform(platform_tag):
                    continue
                
                for abi_tag in parsed.abi_tags:
                    select_arms[(python_tag, platform_tag, abi_tag)] = "@" + target

    # Unfortunately the way that Bazel decides ambiguous selects is explicitly
    # NOT designed to allow for the implementation of ranges. Because that would
    # be too easy. The disambiguation criteria is based on the number of
    # ultimately matching ground conditions, with the most matching winning. No
    # attention is paid to "how far away" those conditions may be down a select
    # chain, for instance down a range ladder.
    #
    # So we have to implement a select with ordering ourselves by testing one
    # condition at a time and taking the first mapped target for the first
    # matching condition.
    #
    # But how do we put all the potential options in an order such that the
    # first match is also the most relevant or newest match? We don't want to
    # take a build which targets glibc 2.0 forever for instance.
    #
    # The answer is tht we have to apply a sorting logic. Specifically we need
    # to sort the platform.
    #
    # The wheel files -> targets pairs come in sorted decending order here, and
    # the wheel name parser reports the annotations also in sorted decending
    # order. So it happens that we SHOULD have the correct behavior here because
    # our insertion order into the select arms dict follows the required
    # newest-match order, but more assurance would be an improvement.
    #
    # Sort triples
    select_arms = sort_select_arms(select_arms)

    # FIXME: Insert the sbuild if it exists with an sbuild config flag
    
    # Convert triples to conditions
    select_arms = {
        "@aspect_rules_py_pip_configurations//:{}-{}-{}".format(*k): v
        for k, v in select_arms.items()
    }

    if repository_ctx.attr.sbuild:
        select_arms = select_arms | {
            "//conditions:default": str(repository_ctx.attr.sbuild)
        }

    content.append(
"""
select_chain(
   name = 'whl',
   arms = {},
)
""".format(
    format_arms(select_arms),
)
)
    # FIXME: May need to add deps to installs here?
    content.append(
"""
whl_install(
   name = "install",
   src = ":whl",
   visibility = ["//visibility:public"],
)
""")
    repository_ctx.file("BUILD.bazel", content = "\n".join(content))


whl_install = repository_rule(
    implementation = _whl_install_impl,
    attrs = {
        "prebuilds": attr.string(),
        "sbuild": attr.label(),
    },
)
