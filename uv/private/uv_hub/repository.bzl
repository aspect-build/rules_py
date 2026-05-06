"""Generates the central hub repository that exposes resolved dependencies to the build.

The hub presents two label shapes:

  - `@<hub>//<package>` — unqualified. The select() arms cover every
    (project, group) provider; resolves cleanly when the active dep_group has
    a single owner of the package, and Bazel's native "multiple keys match"
    surfaces the ambiguity when an active group truly overlaps.

  - `@<hub>//project/<name>:<package>` — project-qualified. Always available.
    The `project/` prefix is reserved on labels because the package side
    comes from PyPI (uncontrolled by the user); without the prefix, picking
    a project name that matches a PyPI package would silently shadow it.
    Flag values, by contrast, are unprefixed (`<name>` / `<name>/<group>`)
    because that namespace is purely user-controlled and the extension
    fails on collision at hub construction time.

Internally each project's groups are namespaced as `<project>__<group>`
config_settings, all keyed on the same global `dep_group` flag value. Setting
`dep_group=prod` activates every project's `prod` group simultaneously; the
qualified aliases route to the right project's package without ambiguity.
"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("//uv/private/pprint:defs.bzl", "pprint")

def indent(text, space = "    "):
    return "\n".join(["{}{}".format(space, l) for l in text.splitlines()])

def _hub_impl(repository_ctx):
    """Lays down the hub repo's BUILD files.

    Sections, in order:

      1. `//dep_group/BUILD.bazel` — alias to the global `dep_group` flag plus
         a `<stamp>__<group>` config_setting per (project, group). Same-named
         groups across projects all key on the same flag value, so
         `dep_group=<group>` activates every project's `<group>`. A narrow
         `<stamp>__q__<group>` config_setting also fires for the qualified
         flag value `<stamp>/<group>` (skipped for `""` — the synthesized
         empty-default — and the synthesized `<stamp>` alias, both already
         addressable via bare flag values).

      2. `//BUILD.bazel` — root, with `gazelle_index_whls`. Selects on the
         active dep_group so only the matching project's whls flow through.

      3. `//project/<stamp>/BUILD.bazel` — per-project subdirs. Qualified
         labels are scoped to one project's groups, so cross-project
         ambiguity is impossible by construction.

      4. `//<package>/BUILD.bazel` — top-level unqualified labels. Providers
         are clustered by (group, versions_tuple); same-version providers in
         the same group share a single canonical arm. Different-version
         providers in the same group form separate clusters and produce
         separate arms — Bazel's "multiple keys match" then surfaces the
         genuine version conflict at `dep_group=<group>`. Each provider
         additionally contributes a per-project narrow arm so
         `dep_group="project/<stamp>/<group>"` resolves unambiguously.

      5. `//defs.bzl` — `compatible_with` / `incompatible_with` helpers.
         User-facing API takes bare group names; helpers fan out to every
         project's namespaced config_setting that matches the group.

      6. `//requirements.bzl` — rules_python compat shim. Returns the
         unqualified label; ambiguous packages surface their helpful
         no_match_error via the alias's select.

    Caveat (sections 4 and 6): the (group, version) dedup ignores override
    differences. Two projects pinning the same version with different
    `uv.override_package` overrides produce differing wheels but only the
    canonical project's overrides apply through the unqualified label.
    Reach for the qualified label or the narrow `project/<stamp>/<group>`
    flag form when overrides diverge.
    """

    # {project_id: {"stamp": ..., "groups": [...], "packages": {pkg: [groups]}}}
    projects = json.decode(repository_ctx.attr.projects)

    # {package: [project_id, ...]}
    package_owners = json.decode(repository_ctx.attr.package_owners)

    # {group_name: [project_stamp, ...]} — used by `compatible_with` to fan
    # a group reference out across every project that defines it.
    projects_by_group = {}
    for project_id, p in projects.items():
        for grp in p["groups"]:
            projects_by_group.setdefault(grp, []).append(p["stamp"])

    all_groups = sorted(projects_by_group.keys())

    # Public group names for defs.bzl: filter out the synthesis sentinel "".
    # PEP 735 forbids empty group names, so "" is an internal artifact and
    # should not appear in DEP_GROUPS or PROJECTS_BY_GROUP. compatible_with("")
    # would silently succeed otherwise, producing confusing behavior.
    public_groups = [g for g in all_groups if g != ""]
    public_projects_by_group = {k: v for k, v in projects_by_group.items() if k != ""}

    ################################################################################
    # //dep_group/BUILD.bazel
    content = [
        """\
alias(
    name = "dep_group",
    actual = "@aspect_rules_py//uv/private/constraints/dep_group:dep_group",
    visibility = ["//visibility:public"],
)
""",
    ]

    for project_id, p in projects.items():
        stamp = p["stamp"]
        for grp in p["groups"]:
            # Broad arm: `dep_group=<group>`.
            content.append("""
config_setting(
    name = "{stamp}__{grp}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/dep_group:dep_group": "{grp}",
    }},
    visibility = ["//visibility:public"],
)
""".format(stamp = stamp, grp = grp))

            # Narrow arm: `dep_group=<stamp>/<group>`.
            if grp != "" and grp != stamp:
                content.append("""
config_setting(
    name = "{stamp}__q__{grp}",
    flag_values = {{
        "@aspect_rules_py//uv/private/constraints/dep_group:dep_group": "{stamp}/{grp}",
    }},
    visibility = ["//visibility:public"],
)
""".format(stamp = stamp, grp = grp))

    content.append("""
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""")

    repository_ctx.file("dep_group/BUILD.bazel", content = "\n".join(content))

    ################################################################################
    # //BUILD.bazel
    # Group projects by dep_group flag value. When two projects share the same
    # group name (e.g. both declare `prod`), their config_settings share the same
    # flag_values — putting both arms in a select() would trigger Bazel's
    # "multiple keys match" error. Use only the canonical (lex-first stamp)
    # config_setting per group value, but collect all matching projects' whls.
    gazelle_groups = {}
    for project_id, p in projects.items():
        for grp in p["groups"]:
            gazelle_groups.setdefault(grp, []).append((p["stamp"], project_id))
    gazelle_arms = {}
    for grp, stamp_pid_pairs in gazelle_groups.items():
        canonical_stamp = sorted([s for s, _ in stamp_pid_pairs])[0]
        gazelle_arms["//dep_group:{}__{}".format(canonical_stamp, grp)] = [
            "@{}//:gazelle_index_whls".format(pid)
            for _, pid in sorted(stamp_pid_pairs)
        ]
    content = [
        """\
load("@aspect_rules_py//py:defs.bzl", "py_library")

filegroup(
    name = "gazelle_index_whls",
    srcs = select({arms}),
    visibility = ["//visibility:public"],
)

exports_files(
    ["defs.bzl", "requirements.bzl"],
    visibility = ["//visibility:public"],
)
""".format(arms = indent(pprint(gazelle_arms), "        ").lstrip()),
    ]
    repository_ctx.file("BUILD.bazel", "\n".join(content))

    ################################################################################
    # //project/<stamp>/BUILD.bazel
    for project_id, p in projects.items():
        stamp = p["stamp"]
        content = [
            """\
load("@aspect_rules_py//py:defs.bzl", "py_library")
""",
        ]

        for package, group_versions in p["packages"].items():
            groups = group_versions.keys()
            target = "@{}//:{}".format(project_id, package)
            target_whl = "@{}//:{}".format(project_id, package + "_whl")
            select_arms = {}
            select_arms_whl = {}
            compat_arms = {}
            for grp in groups:
                broad_key = "//dep_group:{}__{}".format(stamp, grp)
                select_arms[broad_key] = target
                select_arms_whl[broad_key] = target_whl
                compat_arms[broad_key] = []
                if grp != "" and grp != stamp:
                    qualified_key = "//dep_group:{}__q__{}".format(stamp, grp)
                    select_arms[qualified_key] = target
                    select_arms_whl[qualified_key] = target_whl
                    compat_arms[qualified_key] = []
            compat_arms["//conditions:default"] = ["@platforms//:incompatible"]
            no_match_error = "Package `{}` is not in any of project `{}`'s dep_groups: {}".format(
                package,
                stamp,
                ", ".join(sorted(groups)),
            )

            content.append("""
alias(
    name = "{name}",
    actual = select({arms},
        no_match_error = "{err}",
    ),
    target_compatible_with = select({compat}),
    visibility = ["//visibility:public"],
)
alias(
    name = "{name}_whl",
    actual = select({arms_whl},
        no_match_error = "{err}",
    ),
    target_compatible_with = select({compat}),
    visibility = ["//visibility:public"],
)
filegroup(
    name = "{name}.dist_info",
    srcs = [":{name}"],
    target_compatible_with = select({compat}),
    visibility = ["//visibility:public"],
)
""".format(
                name = package,
                arms = indent(pprint(select_arms), "      ").lstrip(),
                arms_whl = indent(pprint(select_arms_whl), "      ").lstrip(),
                compat = indent(pprint(compat_arms), "      ").lstrip(),
                err = no_match_error,
            ))

        repository_ctx.file("project/{}/BUILD.bazel".format(stamp), content = "\n".join(content))

    ################################################################################
    # //<package>/BUILD.bazel
    for package, owners in package_owners.items():
        # {(group, versions_tuple): [owner_id, ...]}
        clusters = {}
        for owner_id in owners:
            for group, versions in projects[owner_id]["packages"][package].items():
                clusters.setdefault((group, tuple(versions)), []).append(owner_id)

        select_arms = {}
        select_arms_whl = {}
        compat_arms = {}
        for cluster_key in sorted(clusters.keys()):
            group, _versions = cluster_key
            cluster_owners = clusters[cluster_key]

            canonical_oid = sorted(cluster_owners, key = lambda oid: projects[oid]["stamp"])[0]
            canonical_stamp = projects[canonical_oid]["stamp"]
            broad_arm = "//dep_group:{}__{}".format(canonical_stamp, group)
            select_arms[broad_arm] = "//project/{}:{}".format(canonical_stamp, package)
            select_arms_whl[broad_arm] = "//project/{}:{}_whl".format(canonical_stamp, package)
            compat_arms[broad_arm] = []

            for owner_id in cluster_owners:
                owner_stamp = projects[owner_id]["stamp"]
                if group != "" and group != owner_stamp:
                    q_arm = "//dep_group:{}__q__{}".format(owner_stamp, group)
                    select_arms[q_arm] = "//project/{}:{}".format(owner_stamp, package)
                    select_arms_whl[q_arm] = "//project/{}:{}_whl".format(owner_stamp, package)
                    compat_arms[q_arm] = []

        compat_arms["//conditions:default"] = ["@platforms//:incompatible"]

        groups_with_pkg_set = {}
        for (grp, _) in clusters.keys():
            groups_with_pkg_set[grp] = True
        groups_with_pkg = sorted(groups_with_pkg_set.keys())
        qualified_labels = sorted([
            "@{}//project/{}:{}".format(repository_ctx.name, projects[o]["stamp"], package)
            for o in owners
        ])
        err = (
            "Package `{pkg}` is available in dep_groups: {groups}. " +
            "If multiple projects in this hub provide `{pkg}` at different " +
            "versions in the active dep_group, Bazel will surface 'multiple keys match' — " +
            "use a project-qualified label instead: {qualified}"
        ).format(
            pkg = package,
            groups = ", ".join(groups_with_pkg),
            qualified = ", ".join(qualified_labels),
        )

        # pkg_alias: guard against the degenerate case where the package is
        # itself named "pkg" — emitting a separate :pkg would collide with :{name}.
        pkg_alias = "" if package == "pkg" else """\
alias(
    name = "pkg",
    actual = ":{name}",
    visibility = ["//visibility:public"],
)
""".format(name = package)

        content = """\
load("@aspect_rules_py//py:defs.bzl", "py_library")

alias(
    name = "{name}",
    actual = select({arms},
        no_match_error = "{err}",
    ),
    target_compatible_with = select({compat}),
    visibility = ["//visibility:public"],
)
alias(
    name = "lib",
    actual = ":{name}",
    visibility = ["//visibility:public"],
)
{pkg_alias}\
alias(
    name = "whl",
    actual = select({arms_whl},
        no_match_error = "{err}",
    ),
    target_compatible_with = select({compat}),
    visibility = ["//visibility:public"],
)
filegroup(
    name = "dist_info",
    srcs = [":{name}"],
    visibility = ["//visibility:public"],
)
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""".format(
            name = package,
            arms = indent(pprint(select_arms), "      ").lstrip(),
            arms_whl = indent(pprint(select_arms_whl), "      ").lstrip(),
            compat = indent(pprint(compat_arms), "      ").lstrip(),
            err = err,
            pkg_alias = pkg_alias,
        )

        repository_ctx.file(package + "/BUILD.bazel", content = content)

    ################################################################################
    # //defs.bzl
    content = ["""\
DEP_GROUPS = {all_groups}
PROJECTS_BY_GROUP = {projects_by_group}
_repo = {repo_name}

def compatible_with(groups, extra_constraints = []):
    for g in groups:
        if g not in PROJECTS_BY_GROUP:
            fail("Errant dep_group reference %r — known groups: %r" % (g, DEP_GROUPS))

    result = {{}}
    for grp in groups:
        for stamp in PROJECTS_BY_GROUP[grp]:
            result[Label("//dep_group:" + stamp + "__" + grp)] = extra_constraints
    result["//conditions:default"] = ["@platforms//:incompatible"]
    return result

def incompatible_with(groups, extra_constraints = []):
    for g in groups:
        if g not in PROJECTS_BY_GROUP:
            fail("Errant dep_group reference %r — known groups: %r" % (g, DEP_GROUPS))

    result = {{}}
    for grp in groups:
        for stamp in PROJECTS_BY_GROUP[grp]:
            result[Label("//dep_group:" + stamp + "__" + grp)] = ["@platforms//:incompatible"]
    result["//conditions:default"] = extra_constraints
    return result
""".format(
        all_groups = pprint(public_groups),
        projects_by_group = pprint(public_projects_by_group),
        repo_name = repr(repository_ctx.name),
    )]

    repository_ctx.file("defs.bzl", content = "\n".join(content))

    ################################################################################
    # //requirements.bzl
    package_names = sorted(package_owners.keys())
    all_pkg_labels = repr([
        "@@{0}//{1}:pkg".format(repository_ctx.name, name)
        for name in package_names
    ])
    all_whl_labels = repr([
        "@@{0}//{1}:whl".format(repository_ctx.name, name)
        for name in package_names
    ])
    all_whl_by_pkg = repr({
        name: "@@{0}//{1}:whl".format(repository_ctx.name, name)
        for name in package_names
    })
    content = """
load("@rules_python//python:pip.bzl", "pip_utils")

all_requirements = {all_requirements}

all_whl_requirements_by_package = {all_whl_by_pkg}

all_whl_requirements = all_whl_requirements_by_package.values()

all_data_requirements = all_requirements

def requirement(name):
    return "@@{repo_name}//{{0}}:pkg".format(pip_utils.normalize_name(name))
""".format(
        all_requirements = all_pkg_labels,
        all_whl_by_pkg = all_whl_by_pkg,
        repo_name = repository_ctx.name,
    )
    repository_ctx.file("requirements.bzl", content = content)

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return repository_ctx.repo_metadata(reproducible = True)

uv_hub = repository_rule(
    doc = """Generates the surface hub repo for a single `uv.hub()` declaration,
aggregating every project bound to it.""",
    implementation = _hub_impl,
    attrs = {
        "projects": attr.string(
            doc = """
            JSON blob: `{project_id: {"stamp": <user-friendly>, "groups": [...], "packages": {pkg: [groups]}}}`.
            """,
        ),
        "package_owners": attr.string(
            doc = """
            JSON blob: `{package: [project_id, ...]}`. >1 owner triggers
            ambiguous-stub generation for the unqualified label.
            """,
        ),
    },
)
