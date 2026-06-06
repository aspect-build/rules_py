"""

Wheel installation repos are actually a bit tricky because this is where we go
from wheel files to a filegroup/py_library. That means we have to perform
platform wheel selection here as well as invoking the installation action to
produce a filegroup/TreeArtifact.

"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")
load("//uv/private/constraints:defs.bzl", "MAJORS", "MINORS")
load("//uv/private/constraints/platform:defs.bzl", "supported_platform")
load("//uv/private/constraints/python:defs.bzl", "supported_python")
load("//uv/private/pprint:defs.bzl", "pprint")

def _find_whl_file(repository_ctx, whl_label):
    """Resolve an http_file-style wheel label to the actual .whl path on disk.

    whl_label typically points at an http_file's filegroup (`//file:file`),
    so `repository_ctx.path` returns the filegroup's logical path — not
    the actual .whl file, which is a sibling in the same directory under
    its downloaded filename. Scan the parent directory to find it.

    Returns None if no .whl file is found.
    """
    logical_path = repository_ctx.path(whl_label)
    parent = logical_path.dirname
    for entry in parent.readdir():
        if entry.basename.endswith(".whl"):
            return entry
    return None

def _extract_wheel_metadata(repository_ctx, whl_label):
    """Peek inside a wheel to discover top-level names and console scripts.

    Mirrors the rules_js `npm_import` pattern of doing partial archive
    extraction at repo-rule time for metadata, rather than deferring to a
    build-time action (which would leave the info invisible to analysis).

    Reads:
      * `*.dist-info/RECORD` (mandatory per PEP 427) to get top-level names.
      * `*.dist-info/entry_points.txt` (optional) to get `[console_scripts]`.

    Both reads go through `unzip -p` (stdout, no disk writes).

    Args:
      repository_ctx: The repo rule context.
      whl_label: A Label pointing at a wheel file (typically an http_file
                 target), passed in via the repo rule's `whl_files`
                 label_list attr so Bazel wires up repo visibility.

    Returns:
      Tuple (top_levels_set, regular_top_levels_set, console_scripts_set,
             dirs_set, init_dirs_set):
        * top_levels_set: dict[name → True] — all first-path-segment
          names in RECORD (excluding `*.data/` staging entries).
        * regular_top_levels_set: subset that had an `__init__.py` at
          depth 1, i.e. regular packages. Its complement (within
          top_levels_set, minus `.dist-info/`) is the PEP 420 namespace
          set. Returned separately so callers can union regular/top sets
          across multiple platform wheels before deriving namespaces —
          a top-level is a namespace only if NO wheel has it as regular.
        * console_scripts_set: dict[script_name → "name=module:func"].
        * dirs_set: dict[path → True] — every directory implied by a
          RECORD entry, as a `/`-joined relative path.
        * init_dirs_set: dict[path → True] — subset of dirs_set that
          directly contain an `__init__.py` (regular packages).
      All empty on any failure — callers tolerate empty and fall back.
    """
    unzip = repository_ctx.which("unzip")
    if not unzip:
        return {}, {}, {}, {}, {}

    whl_path = _find_whl_file(repository_ctx, whl_label)
    if whl_path == None:
        return {}, {}, {}, {}, {}

    # RECORD: authoritative list of every installed file. First path segment
    # = top-level name, excluding the wheel's `*.data/` staging area.
    record = repository_ctx.execute([unzip, "-p", str(whl_path), "*.dist-info/RECORD"])
    top_levels_set = {}

    # Tracks which top-levels contain a direct `<toplevel>/__init__.py` —
    # i.e., are regular packages. The complement (top_levels that never
    # appear with an `__init__.py` at depth 1) are PEP 420 namespace
    # packages that expect to be merged across wheels.
    regular_top_levels = {}

    # Full directory skeleton + which directories hold an `__init__.py`.
    # Powers the namespace_dirs / regular_roots derivation in the caller,
    # which venv assembly uses to detect regular packages spanning wheels
    # (e.g. azure-core-tracing-opentelemetry grafting into azure-core's
    # `azure/core/tracing/` tree).
    dirs_set = {}
    init_dirs_set = {}
    if record.return_code == 0 and record.stdout:
        for line in record.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            path = line.split(",", 1)[0]
            if not path:
                continue
            segments = path.split("/")
            first_segment = segments[0]

            # `*.data/` files (PEP 427) aren't installed to site-packages;
            # they're routed to data/scripts/headers/purelib/etc. under
            # sys.prefix. Exclude from site-packages top-level list.
            if first_segment.endswith(".data"):
                continue

            # Filter RECORD entries that escape the install root. Some
            # wheels (notably setuptools-family) emit lines like
            # `../../bin/foo` for entry-point scripts. We don't want
            # `..` / `.` / absolute paths / empty strings in top_levels
            # because downstream `ctx.actions.declare_symlink` normalises
            # paths and would create phantom outputs at parent dirs,
            # producing prefix-collision errors.
            if not first_segment:
                continue
            if first_segment in (".", ".."):
                continue
            if first_segment.startswith("/"):
                continue
            top_levels_set[first_segment] = True

            # Single-file modules (e.g. `six.py` at top level) aren't
            # namespace packages — treat them as regular.
            if len(segments) == 1 or (len(segments) >= 2 and segments[1] == "__init__.py"):
                regular_top_levels[first_segment] = True

            # Record every directory along the path, and which of them
            # directly contain an `__init__.py`.
            for i in range(1, len(segments)):
                dirs_set["/".join(segments[:i])] = True
            if segments[-1] == "__init__.py" and len(segments) >= 2:
                init_dirs_set["/".join(segments[:-1])] = True

    # entry_points.txt: INI-style file. Only `[console_scripts]` interests
    # us — pip/uv synthesize executables under `bin/<name>` from those at
    # install time. Missing file is normal (lots of libs have no scripts).
    ep = repository_ctx.execute([unzip, "-p", str(whl_path), "*.dist-info/entry_points.txt"])
    console_scripts = {}
    if ep.return_code == 0 and ep.stdout:
        in_console_scripts = False
        for raw_line in ep.stdout.splitlines():
            # Strip comments (`;` or `#`) and whitespace.
            line = raw_line.split(";", 1)[0].split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                in_console_scripts = line[1:-1].strip() == "console_scripts"
                continue
            if not in_console_scripts:
                continue
            if "=" not in line:
                continue
            name, _, target = line.partition("=")
            name = name.strip()
            target = target.strip()
            if not name or ":" not in target:
                continue

            # Normalise to "name=module:func" so downstream parsing is trivial.
            console_scripts[name] = "{}={}".format(name, target)

    # Return raw sets (not the final namespace derivation) so callers can
    # union across multiple platform wheels before deciding namespace
    # status — see the caller in `_whl_install_repo_impl`.
    return top_levels_set, regular_top_levels, console_scripts, dirs_set, init_dirs_set

def indent(text, space = " "):
    return "\n".join(["{}{}".format(space, l) for l in text.splitlines()])

def _format_arms(d):
    content = ["        \"{}\": \"{}\"".format(k, v) for k, v in d.items()]
    content = ",\n".join(content)
    return "{\n" + content + "\n   }"

def select_key(triple):
    """Force (triple, target) pairs into a orderable form.

    In order to impose _sequential_ selection on whl arms, we need to impose an
    ordering on platform triples. The way we do this is by coercing "platform
    triples" into:

    - The interpreter (major, minor) pair which  is orderable
    - _assuming_ that platform versions are lexically orderable
    - _assuming_ that ABI is effectively irrelevant to ordering

    This allows us to produce a tuple which will sort roughly according to the
    desired preference order among wheels which COULD be compatible with the
    same platform.

    """

    python, platform, abi = triple

    # Build a key for the interpreter
    py_major = int(python[2])
    py_minor = int(python[3:]) if python[3:] else 0
    py = (py_major, py_minor)

    # FIXME: It'd be WAY better if we could enforce a stronger order here
    platform = platform.split("_")
    if platform[0] in ["manylinux", "musllinux", "macosx"]:
        platform = (int(platform[1]), int(platform[2]))
    else:
        # Really case of windows; potential BSD issues?
        platform = (0, 0)

    # Build a key for the ABI.
    #
    # We want to prefer the most specific (eg. cp312t) build over a more generic
    # build (cp312). In order to achieve this, we check the ABI string for
    # specific feature flags and we set those flags to 1 rather than 0 before
    # including them in the sorting key.
    d = 1 if "d" in abi else 0
    m = 1 if "m" in abi else 0
    t = 1 if "t" in abi else 0
    u = 1 if "u" in abi else 0

    # In order to get the most specific match first, we score the abi by the
    # number of flags set and we sort wheels with highly specific ABIs first.
    flags = (d + m + t + u)
    abi = (flags, d, m, t, u, abi)

    return (py, platform, abi)

def sort_select_arms(arms):
    # {(python, platform, abi): target}
    pairs = sorted(arms.items(), key = lambda kv: select_key(kv[0]), reverse = True)
    return {a: b for a, b in pairs}

def compatible_python_tags(python_tag, abi_tag):
    if abi_tag != "abi3" or not python_tag.startswith("cp"):
        return [python_tag]

    major = int(python_tag[2])
    minor = int(python_tag[3:]) if python_tag[3:] else 0
    compatible = []
    for candidate_major in MAJORS:
        if candidate_major != major:
            continue
        for candidate_minor in MINORS:
            if candidate_minor < minor:
                continue

            candidate = "cp{}{}".format(candidate_major, candidate_minor)
            if supported_python(candidate):
                compatible.append(candidate)

    return compatible if compatible else [python_tag]

def source_specificity(python_tag):
    """Score how specific a wheel's source python_tag is.

    Two abi3 wheels can expand into the same (compatible_python, platform,
    abi) key — e.g. both a cp38-abi3 and a cp311-abi3 wheel cover cp312+.
    Among those, the wheel with the higher minimum-CPython requirement is
    the most specific match and should win. Returned as an orderable tuple.
    """
    if not python_tag.startswith("cp"):
        return (0, 0)
    major = int(python_tag[2])
    minor = int(python_tag[3:]) if python_tag[3:] else 0
    return (major, minor)

def _whl_install_impl(repository_ctx):
    """Selects a compatible wheel for the host platform and defines its installation.

    This rule takes a dictionary of available pre-built wheels and an optional
    wheel built from source (`sbuild`). It is responsible for generating the
    logic to select the single, most appropriate wheel for the current target
    platform.

    It generates a `BUILD.bazel` file that:
    1.  Uses a custom `select_chain` rule to create a sequence of `select`
        statements. This chain checks the current platform against the
        compatibility triples of the available wheels (using the `config_setting`s
        generated by `configurations_hub`) and picks the first, most specific match.
    2.  If an `sbuild` target is provided, it is used as the default fallback in
        the selection chain, for when no pre-built wheel is compatible.
    3.  Feeds the selected wheel file into a `whl_install` build rule, which is
        responsible for unpacking the wheel into a directory.
    4.  Provides a final `install` alias that represents the installed content of
        the chosen wheel.

    Args:
        repository_ctx: The repository context.
    """
    prebuilds = json.decode(repository_ctx.attr.whls)
    # Prebuilds is a mapping from whl file name to repo labels which contain
    # that file. We need to take these wheel files and parse out compatibility.
    #
    # This is complicated by Starlark as with Python not treating lists as
    # values, so we have to go to strings of JSON in order to get value
    # semantics which is frustrating.

    # The strategy here is to roll through the wheels,
    select_arms = {}
    content = [
        "load(\"@aspect_rules_py//py:defs.bzl\", \"py_library\")",
        "load(\"@aspect_rules_py//uv/private/whl_install:defs.bzl\", \"select_chain\")",
        "load(\"@aspect_rules_py//uv/private/whl_install:rule.bzl\", \"whl_install\")",
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    # During expansion the value is (source_specificity, target). When two
    # abi3 wheels claim the same (compatible_python, platform, abi) key —
    # e.g. cp38-abi3 and cp311-abi3 both expand into cp312+ — the wheel
    # with the higher source minor must win, regardless of iteration order.
    for whl, target in prebuilds.items():
        parsed = parse_whl_name(whl)

        # FIXME: Make it impossible to generate absurd combinations such as
        # cp212-none-cp312 with unsatisfiable version specs.
        for platform_tag in parsed.platform_tags:
            # Escape hatch for ignoring weird unsupported platforms
            if not supported_platform(platform_tag):
                continue

            for abi_tag in parsed.abi_tags:
                for python_tag in parsed.python_tags:
                    specificity = source_specificity(python_tag)
                    for compatible_python_tag in compatible_python_tags(python_tag, abi_tag):
                        # Escape hatch for ignoring unsupported interpreters
                        if not supported_python(compatible_python_tag):
                            continue

                        key = (compatible_python_tag, platform_tag, abi_tag)
                        existing = select_arms.get(key)
                        if existing == None or specificity > existing[0]:
                            select_arms[key] = (specificity, target)

    # Strip the bookkeeping specificity score; downstream only needs the target.
    select_arms = {k: v[1] for k, v in select_arms.items()}

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
    # The answer is that we have to apply a sorting logic. Specifically we need
    # to sort the platform.
    #
    # The wheel files -> targets pairs come in sorted descending order here, and
    # the wheel name parser reports the annotations also in sorted descending
    # order. So it happens that we SHOULD have the correct behavior here because
    # our insertion order into the select arms dict follows the required
    # newest-match order, but more assurance would be an improvement.
    #
    # Sort triples
    select_arms = sort_select_arms(select_arms)

    # FIXME: Insert the sbuild if it exists with an sbuild config flag as the
    # first condition so that the user can force the build to use _only_ sbuilds
    # if available (or transition a target to mandate sbuild).

    # Convert triples to conditions
    select_arms = {
        "@aspect_rules_py_pip_configurations//:{}-{}-{}".format(*k): v
        for k, v in select_arms.items()
    }

    default_target = str(repository_ctx.attr.sbuild) if repository_ctx.attr.sbuild else None

    if (select_arms or prebuilds) and not default_target:
        default_target = ":whl_missing"
        content.append(
            """
py_library(
    name = "whl_missing",
    srcs = [],
    target_compatible_with = ["@platforms//:incompatible"],
    visibility = ["//visibility:private"],
)
""",
        )

    if prebuilds:
        gazelle_index_whl = prebuilds.values()[0]  # Effectively random choice :shrug:
    elif default_target:
        gazelle_index_whl = default_target
    else:
        fail("Cannot identify a wheel or sbuild of {} to analyze for Gazelle indexing\n{}".format(repository_ctx.name, pprint(repository_ctx.attr)))

    content.append(
        """
select_chain(
   name = "whl",
   arms = {arms},
   default_target = {default_target},
   visibility = ["//visibility:public"],
)

filegroup(
    name = "gazelle_index_whl",
    srcs = {index_whl},
    visibility = ["//visibility:public"],
)
""".format(
            arms = _format_arms(select_arms),
            default_target = repr(default_target),
            index_whl = indent(pprint([str(gazelle_index_whl)]), " " * 4).lstrip(),
        ),
    )

    post_install_patches = json.decode(repository_ctx.attr.post_install_patches) if repository_ctx.attr.post_install_patches else []
    post_install_patch_strip = repository_ctx.attr.post_install_patch_strip

    extra_deps = json.decode(repository_ctx.attr.extra_deps) if repository_ctx.attr.extra_deps else []
    extra_data = json.decode(repository_ctx.attr.extra_data) if repository_ctx.attr.extra_data else []

    compile_pyc_select = """select({
        "@aspect_rules_py//uv/private/pyc:is_precompile": True,
        "//conditions:default": False,
    })"""

    pyc_invalidation_mode_select = """select({
        "@aspect_rules_py//uv/private/pyc:is_unchecked_hash": "unchecked-hash",
        "@aspect_rules_py//uv/private/pyc:is_timestamp": "timestamp",
        "//conditions:default": "checked-hash",
    })"""

    # Peek into each wheel to extract the top-level names it installs AND
    # its `[console_scripts]` entry points. This powers PyWheelsInfo,
    # which py_binary uses to build a merged site-packages tree via
    # ctx.actions.symlink and to wrap console scripts into <venv>/bin/.
    # Falls back gracefully to [] if extraction fails; consumers tolerate it.
    #
    # We read from `whl_files` (a real label_list) rather than `whls` (a
    # JSON-encoded string of labels) because only the former adds the
    # wheel repos to our visibility so `rctx.path(Label(...))` can resolve.
    #
    # Union across all platform wheels — same-python-version wheels for
    # a given package share their pure-Python top-levels but have
    # DIFFERENT C-extension filenames (e.g. cffi's `_cffi_backend` ships
    # as `_cffi_backend.cpython-311-darwin.so` on macOS and
    # `_cffi_backend.cpython-311-x86_64-linux-gnu.so` on Linux). Picking
    # only one wheel bakes in that wheel's suffix; at build time on a
    # different platform, the venv's top-level symlink points at a file
    # that doesn't exist in the actually-installed wheel. Unioning lets
    # every platform see its own suffix in top_levels — the dangling
    # symlinks for other platforms' suffixes are invisible to Python's
    # importer (it matches by the current interpreter's exact suffix).
    top_levels_set = {}
    regular_top_levels_set = {}
    console_scripts_set = {}
    dirs_set = {}
    init_dirs_set = {}
    for whl_file in repository_ctx.attr.whl_files:
        tls, reg, css, dirs, init_dirs = _extract_wheel_metadata(repository_ctx, whl_file)
        top_levels_set.update(tls)
        regular_top_levels_set.update(reg)
        console_scripts_set.update(css)
        dirs_set.update(dirs)
        init_dirs_set.update(init_dirs)

    # Namespace derivation happens AFTER the union: a top-level counts as
    # a PEP 420 namespace only if NO extracted wheel had `__init__.py` at
    # depth 1 for it. If any wheel flagged it regular, it's regular.
    top_levels = sorted(top_levels_set.keys())
    namespace_top_levels = sorted([
        tl
        for tl in top_levels_set
        if tl not in regular_top_levels_set and not tl.endswith(".dist-info")
    ])
    console_scripts = sorted(console_scripts_set.values())

    # Classify every directory under a namespace top-level. Walking from
    # the top, content is an implicit-namespace portion until the first
    # directory carrying an `__init__.py` — that directory is a "regular
    # root" and everything below it is interior to a regular package.
    #
    #   * namespace_dirs: the implicit-namespace skeleton, minus the
    #     depth-1 entries already covered by namespace_top_levels
    #     (azure-core → []; azure-core-tracing-opentelemetry →
    #     ["azure/core", "azure/core/tracing", "azure/core/tracing/ext"]).
    #   * regular_roots: the minimal regular-package dirs (azure-core →
    #     ["azure/core"]).
    #
    # venv assembly cross-references these across wheels: a regular root
    # appearing in another wheel's namespace skeleton means a regular
    # package SPANS wheels — Python's namespace machinery cannot merge
    # that, so the subtree must be physically merged. Dirs under regular
    # top-levels are skipped: those collisions are already handled by the
    # top-level first-wins policy.
    namespace_top_levels_set = {tl: True for tl in namespace_top_levels}
    namespace_dirs = []
    regular_roots = []
    for d in sorted(dirs_set.keys()):
        segments = d.split("/")
        if segments[0] not in namespace_top_levels_set:
            continue
        boundary = None
        for i in range(len(segments)):
            prefix = "/".join(segments[:i + 1])
            if prefix in init_dirs_set:
                boundary = prefix
                break
        if boundary == None:
            # Depth-1 entries are redundant with namespace_top_levels
            # (regular roots are always depth >= 2, so the cross-wheel
            # scan never consults them) — dropping them keeps wheels
            # with only a `<pkg>.libs/` shared-library dir attr-free.
            if len(segments) >= 2:
                namespace_dirs.append(d)
        elif boundary == d:
            regular_roots.append(d)

    install_attrs = """
    src = ":whl",
    compile_pyc = {compile_pyc},
    pyc_invalidation_mode = {pyc_invalidation_mode},
    top_levels = {top_levels},
    namespace_top_levels = {namespace_top_levels},
    console_scripts = {console_scripts},""".format(
        compile_pyc = compile_pyc_select,
        pyc_invalidation_mode = pyc_invalidation_mode_select,
        top_levels = repr(top_levels),
        namespace_top_levels = repr(namespace_top_levels),
        console_scripts = repr(console_scripts),
    )

    # Only emitted for wheels that contribute to a namespace — keeps the
    # generated BUILD files (and their e2e snapshots) unchanged for the
    # common regular-top-level case.
    if namespace_dirs or regular_roots:
        install_attrs += """
    namespace_dirs = {namespace_dirs},
    regular_roots = {regular_roots},""".format(
            namespace_dirs = repr(namespace_dirs),
            regular_roots = repr(regular_roots),
        )

    if post_install_patches:
        install_attrs += """
    patches = {patches},
    patch_strip = {strip},""".format(
            patches = repr(post_install_patches),
            strip = post_install_patch_strip,
        )

    content.append(
        """
whl_install(
    name = "actual_install",{attrs}
    visibility = ["//visibility:private"],
)""".format(attrs = install_attrs),
    )

    if extra_deps or extra_data:
        # When extra deps/data are needed, wrap in a py_library instead of alias
        content.append(
            """
py_library(
    name = "install",
    srcs = [],
    deps = [":actual_install"] + {extra_deps},
    data = {extra_data},
    visibility = ["//visibility:public"],
)
""".format(
                extra_deps = repr(extra_deps),
                extra_data = repr(extra_data),
            ),
        )
    else:
        content.append(
            """
alias(
    name = "install",
    actual = ":actual_install",
    visibility = ["//visibility:public"],
)
""",
        )

    content.append("""
exports_files(
    ["BUILD.bazel"],
    visibility = ["//visibility:public"],
)
""")

    repository_ctx.file("BUILD.bazel", content = "\n".join(content))

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return repository_ctx.repo_metadata(reproducible = True)

whl_install = repository_rule(
    implementation = _whl_install_impl,
    attrs = {
        "whls": attr.string(),
        # Mirror of the http_file labels from `whls`, declared as a real
        # label_list so Bazel adds those repos to this repo's visibility
        # mapping. Needed so that `repository_ctx.path(Label(...))` can
        # resolve any one of them at repo-rule time to peek at the wheel's
        # `*.dist-info/RECORD` — see `_extract_top_levels` above.
        "whl_files": attr.label_list(allow_files = [".whl"]),
        "sbuild": attr.label(),
        "post_install_patches": attr.string(default = ""),
        "post_install_patch_strip": attr.int(default = 0),
        "extra_deps": attr.string(default = ""),
        "extra_data": attr.string(default = ""),
    },
)
