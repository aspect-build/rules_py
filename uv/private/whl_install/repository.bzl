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

def parse_record_path(line):
    """Return the path field from one CSV-encoded wheel RECORD row."""
    line = line.strip()
    if not line:
        return ""
    if not line.startswith("\""):
        return line.split(",", 1)[0]

    path = []
    skip_quote = False
    for index in range(1, len(line)):
        if skip_quote:
            skip_quote = False
            continue
        char = line[index]
        if char != "\"":
            path.append(char)
        elif index + 1 < len(line) and line[index + 1] == "\"":
            path.append("\"")
            skip_quote = True
        else:
            if index + 1 < len(line) and line[index + 1] != ",":
                fail("invalid wheel RECORD row: unexpected text after quoted path")
            return "".join(path)

    fail("invalid wheel RECORD row: unterminated quoted path")

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

    Bazel's repository API extracts the wheel's required metadata directory.

    Args:
      repository_ctx: The repo rule context.
      whl_label: A Label pointing at a wheel file (typically an http_file
                 target), passed in via the repo rule's `whl_files`
                 label_list attr so Bazel wires up repo visibility.

    Returns:
      Tuple (whl_basename, top_levels_set, directory_top_levels_set,
             regular_top_levels_set, console_scripts_set,
             namespace_entries_set, dirs_set, init_dirs_set):
        * whl_basename: basename of the wheel file resolved from whl_label.
        * top_levels_set: dict[name → True] — all first-path-segment
          names installed into site-packages. RECORD entries under
          `*.data/{purelib,platlib}/` are made site-packages-relative first.
        * directory_top_levels_set: subset installed as directories rather
          than individual files.
        * regular_top_levels_set: subset with a direct `__init__.py`, plus
          top-level modules.
        * console_scripts_set: dict[script_name → "name=module:func"].
        * namespace_entries_set: dict[path → True] — shallowest concrete
          entries beneath each namespace top-level.
        * dirs_set: dict[path → True] — every directory implied by RECORD.
        * init_dirs_set: subset of dirs_set that directly contain an
          `__init__.py`.
      Fails if the archive cannot be inspected. Missing metadata would make
      package collision handling silently incorrect.
    """
    whl_path = _find_whl_file(repository_ctx, whl_label)
    if whl_path == None:
        fail("{}: could not find wheel for {}".format(repository_ctx.name, whl_label))
    metadata_dir = "_wheel_metadata"
    metadata_directory = repository_ctx.attr.metadata_directory
    if not metadata_directory:
        fail("{}: no metadata directory is known for wheel {}".format(
            repository_ctx.name,
            whl_path,
        ))
    if not metadata_directory.endswith(".dist-info"):
        fail("{}: invalid metadata directory {} for wheel {}".format(
            repository_ctx.name,
            metadata_directory,
            whl_path,
        ))
    data_directory = metadata_directory[:-len(".dist-info")] + ".data"

    # Bazel only learned that .whl files are ZIP archives in
    # https://github.com/bazelbuild/bazel/commit/d9634ca1c143136ef3b02b5ad8876a62368762b5.
    # Extract through a ZIP-named symlink so this remains compatible with
    # older Bazel releases supported by rules_py.
    metadata_archive = "_wheel_metadata.zip"
    repository_ctx.delete(metadata_dir)
    repository_ctx.delete(metadata_archive)
    repository_ctx.symlink(whl_path, metadata_archive)
    repository_ctx.extract(
        archive = metadata_archive,
        output = metadata_dir,
        strip_prefix = metadata_directory,
    )
    repository_ctx.delete(metadata_archive)
    metadata_path = repository_ctx.path(metadata_dir)
    record_path = metadata_path.get_child("RECORD")
    if not record_path.exists:
        fail("{}: wheel {} has no {}/RECORD".format(
            repository_ctx.name,
            whl_path,
            metadata_directory,
        ))
    record = repository_ctx.read(record_path)
    entry_points = ""
    entry_points_path = metadata_path.get_child("entry_points.txt")
    if entry_points_path.exists:
        entry_points = repository_ctx.read(entry_points_path)
    repository_ctx.delete(metadata_dir)

    # RECORD: authoritative list of every installed file. First path segment
    # = top-level name after translating wheel install-scheme paths.
    top_levels_set = {}
    directory_top_levels = {}
    regular_top_levels = {}
    record_segments = []
    dirs_set = {}
    init_dirs = {}
    if record:
        for line in record.splitlines():
            path = parse_record_path(line)
            if not path:
                continue
            segments = path.split("/")

            # PEP 427 spreads purelib and platlib into their installation
            # scheme directories. unpack.py maps both to this rule's
            # site-packages tree; scripts, headers, and data live elsewhere.
            # https://packaging.python.org/specifications/binary-distribution-format/#the-data-directory
            if segments[0] == data_directory:
                if len(segments) < 3 or segments[1] not in ("purelib", "platlib"):
                    continue
                segments = segments[2:]

            first_segment = segments[0]

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
            if len(segments) > 1:
                directory_top_levels[first_segment] = True
            if len(segments) == 1 or (len(segments) >= 2 and segments[1] == "__init__.py"):
                regular_top_levels[first_segment] = True

            record_segments.append(segments)
            for i in range(1, len(segments)):
                dirs_set["/".join(segments[:i])] = True
            if len(segments) >= 2 and segments[-1] == "__init__.py":
                init_dirs["/".join(segments[:-1])] = True

    # Identify the shallowest concrete entry below each namespace top-level:
    # a regular package directory or a file. Per-entry links let namespace
    # wheels share one site-packages directory without moving their contents
    # away from wheel-local resources.
    namespace_entries = {}
    for segments in record_segments:
        if segments[0] in regular_top_levels or segments[0].endswith(".dist-info"):
            continue
        if len(segments) < 2:
            continue
        for depth in range(2, len(segments) + 1):
            prefix = "/".join(segments[:depth])
            if depth == len(segments) or prefix in init_dirs:
                namespace_entries[prefix] = True
                break

    # entry_points.txt: INI-style file. Only `[console_scripts]` interests
    # us — pip/uv synthesize executables under `bin/<name>` from those at
    # install time. Missing file is normal (lots of libs have no scripts).
    console_scripts = {}
    if entry_points:
        in_console_scripts = False
        for raw_line in entry_points.splitlines():
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
            module, _, func_extras = target.partition(":")
            module = module.strip()
            func = func_extras.split("[")[0].strip()
            if not name or not module or not func:
                continue

            # Legacy entry-point extras may be parsed and ignored:
            # https://packaging.python.org/en/latest/specifications/entry-points/#data-model
            console_scripts[name] = "{}={}:{}".format(
                name,
                module,
                func,
            )

    return (
        whl_path.basename,
        top_levels_set,
        directory_top_levels,
        regular_top_levels,
        console_scripts,
        namespace_entries,
        dirs_set,
        init_dirs,
    )

def _namespace_dirs_and_roots(dirs_set, init_dirs, namespace_top_levels_set):
    """Classify directories below namespace top-levels.

    Content remains an implicit namespace until the first directory carrying
    an `__init__.py`. That boundary is a regular package root. Comparing one
    wheel's regular roots with another wheel's namespace skeleton identifies
    packages that a flat installation overlays across wheels.
    """
    namespace_dirs = []
    regular_roots = []
    for directory in sorted(dirs_set.keys()):
        segments = directory.split("/")
        if segments[0] not in namespace_top_levels_set:
            continue
        boundary = None
        for i in range(len(segments)):
            prefix = "/".join(segments[:i + 1])
            if prefix in init_dirs:
                boundary = prefix
                break
        if boundary == None:
            if len(segments) >= 2:
                namespace_dirs.append(directory)
        elif boundary == directory:
            regular_roots.append(directory)
    return namespace_dirs, regular_roots

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

    # Wheel targets that survived platform/interpreter filtering — the only
    # wheels the select chain below can ever resolve to. Used to limit
    # metadata extraction to selectable wheels.
    arm_targets = {v: True for v in select_arms.values()}

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

    # Peek into each selectable wheel to extract the top-level names it
    # installs AND its `[console_scripts]` entry points, keyed by the
    # wheel's file basename. This powers PyWheelsInfo, which py_binary
    # uses to build a merged site-packages tree via ctx.actions.symlink
    # and to wrap console scripts into <venv>/bin/.
    #
    # Metadata is kept per wheel rather than unioned across the platform
    # wheels: the `whl_install` build rule looks up the entry whose key
    # matches the basename of the wheel the select chain resolved to for
    # the active configuration. A union would leak an inactive wheel's
    # package surface into the active one — e.g. cffi's macOS
    # `_cffi_backend.cpython-312-darwin.so` top-level showing up (as a
    # dangling site-packages symlink) in a Linux build, or a console
    # script shipped only by the win32 wheel getting a `<venv>/bin/`
    # wrapper pointing at a module that doesn't exist on Linux.
    #
    # Wheels that didn't make it into the select chain (unsupported
    # platform/interpreter) are skipped — they can never be the active
    # wheel, and peeking at them would force a useless download.
    #
    # Metadata is mandatory for selected wheels. Silent failure would omit
    # collision and console-script data based on which ambient tools happen
    # to be installed, changing the generated virtualenv.
    #
    # We read from `whl_files` (a real label_list) rather than `whls` (a
    # JSON-encoded string of labels) because only the former adds the
    # wheel repos to our visibility so `rctx.path(Label(...))` can
    # resolve. `whl_files` mirrors the truthy `whls` values in order, so
    # pair them up by index to recover the target ↔ label association.
    # Both lists are generated together by the hub rule from the same
    # source data, so the ordering invariant is maintained at the point
    # of production and does not depend on runtime dict iteration order.
    whl_file_labels = {}
    whl_file_index = 0
    for target in prebuilds.values():
        if not target:
            continue
        whl_file_labels[target] = repository_ctx.attr.whl_files[whl_file_index]
        whl_file_index += 1

    top_levels_by_whl = {}
    directory_top_levels_by_whl = {}
    namespace_top_levels_by_whl = {}
    namespace_entries_by_whl = {}
    namespace_dirs_by_whl = {}
    regular_roots_by_whl = {}
    console_scripts_by_whl = {}
    for target, whl_file_label in whl_file_labels.items():
        if target not in arm_targets:
            continue
        whl_name, tls, directory_tls, regular, css, ns_entries, dirs_set, init_dirs = _extract_wheel_metadata(
            repository_ctx,
            whl_file_label,
        )
        if tls:
            top_levels_by_whl[whl_name] = sorted(tls.keys())
            namespaces = sorted([
                tl
                for tl in tls
                if tl not in regular and not tl.endswith(".dist-info")
            ])
            if namespaces:
                namespace_top_levels_by_whl[whl_name] = namespaces
                namespace_set = {tl: True for tl in namespaces}
                entries = sorted([
                    entry
                    for entry in ns_entries
                    if entry.split("/")[0] in namespace_set
                ])
                if entries:
                    namespace_entries_by_whl[whl_name] = entries
                namespace_dirs, regular_roots = _namespace_dirs_and_roots(
                    dirs_set,
                    init_dirs,
                    namespace_set,
                )
                if namespace_dirs:
                    namespace_dirs_by_whl[whl_name] = namespace_dirs
                if regular_roots:
                    regular_roots_by_whl[whl_name] = regular_roots
        if directory_tls:
            directory_top_levels_by_whl[whl_name] = sorted(directory_tls.keys())
        if css:
            console_scripts_by_whl[whl_name] = sorted(css.values())

    install_attrs = """
    src = ":whl",
    compile_pyc = {compile_pyc},
    pyc_invalidation_mode = {pyc_invalidation_mode},
    top_levels = {top_levels},
    directory_top_levels = {directory_top_levels},
    namespace_top_levels = {namespace_top_levels},
    console_scripts = {console_scripts},""".format(
        compile_pyc = compile_pyc_select,
        pyc_invalidation_mode = pyc_invalidation_mode_select,
        top_levels = indent(pprint(top_levels_by_whl), " " * 4).lstrip(),
        directory_top_levels = indent(pprint(directory_top_levels_by_whl), " " * 4).lstrip(),
        namespace_top_levels = indent(pprint(namespace_top_levels_by_whl), " " * 4).lstrip(),
        console_scripts = indent(pprint(console_scripts_by_whl), " " * 4).lstrip(),
    )

    if namespace_entries_by_whl:
        install_attrs += """
    namespace_entries = {namespace_entries},""".format(
            namespace_entries = indent(pprint(namespace_entries_by_whl), " " * 4).lstrip(),
        )
    if namespace_dirs_by_whl or regular_roots_by_whl:
        install_attrs += """
    namespace_dirs = {namespace_dirs},
    regular_roots = {regular_roots},""".format(
            namespace_dirs = indent(pprint(namespace_dirs_by_whl), " " * 4).lstrip(),
            regular_roots = indent(pprint(regular_roots_by_whl), " " * 4).lstrip(),
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
        "metadata_directory": attr.string(),
        "whls": attr.string(),
        # Mirror of the http_file labels from `whls`, declared as a real
        # label_list so Bazel adds those repos to this repo's visibility
        # mapping. Needed so that `repository_ctx.path(Label(...))` can
        # resolve any one of them at repo-rule time to peek at the wheel's
        # `*.dist-info/RECORD` — see `_extract_wheel_metadata` above.
        "whl_files": attr.label_list(allow_files = [".whl"]),
        "sbuild": attr.label(),
        "post_install_patches": attr.string(default = ""),
        "post_install_patch_strip": attr.int(default = 0),
        "extra_deps": attr.string(default = ""),
        "extra_data": attr.string(default = ""),
    },
)
