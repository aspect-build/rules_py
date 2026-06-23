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
    """Return the path field from one CSV-encoded wheel RECORD row.

    RECORD is a CSV file in Python's default `csv` reader dialect (`,`
    delimiter, `"` quote char, `""` -> `"` escaping, no whitespace trimming):
    https://packaging.python.org/en/latest/specifications/recording-installed-packages/#the-record-file
    https://docs.python.org/3/library/csv.html#csv.reader

    Parses the first field of one row the way `csv.reader` would, matching
    CPython's RECORD reader `importlib.metadata.Distribution.files` (which also
    does `read_text("RECORD").splitlines()` then `csv.reader` per line):
    https://github.com/python/cpython/blob/main/Lib/importlib/metadata/__init__.py

    NOTE: because RECORD is split per line before this is called, a quoted path
    containing an embedded newline (legal but vanishingly rare) is not handled
    -- the same limitation `importlib.metadata` has.
    """
    path = []

    # States mirror csv.reader's field parser:
    #   start       - at the field boundary, before any character
    #   unquoted    - inside an unquoted field; `"` is a literal character
    #   quoted      - inside a quoted field; `,` is a literal character
    #   after_quote - just saw a `"` while quoted; decide escape vs. close
    state = "start"
    for index in range(len(line)):
        char = line[index]
        if state == "start":
            if char == ",":
                return ""
            elif char == "\"":
                state = "quoted"
            else:
                path.append(char)
                state = "unquoted"
        elif state == "unquoted":
            if char == ",":
                return "".join(path)
            path.append(char)
        elif state == "quoted":
            if char == "\"":
                state = "after_quote"
            else:
                path.append(char)
        else:  # after_quote
            if char == "\"":
                path.append("\"")  # doubled quote -> literal `"`
                state = "quoted"
            elif char == ",":
                return "".join(path)
            else:
                path.append(char)  # text after a closing quote
                state = "unquoted"

    return "".join(path)

def site_packages_segments(path, data_directory):
    """Map a RECORD path to its installed site-packages segments."""
    segments = path.split("/")
    if segments[0] != data_directory:
        return segments
    if len(segments) < 3:
        return []
    category = segments[1]
    if category in ("purelib", "platlib"):
        return segments[2:]
    if category in ("data", "headers", "scripts"):
        return []

    # Keep this in sync with py/tools/unpack/unpack.py: unknown categories
    # retain their category prefix under site-packages.
    return segments[1:]

def parse_console_script(line):
    """Parse one `[console_scripts]` entry into a canonical `name=module:func`.

    `line` is a single `name = module:func [extras]` assignment; section
    headers, comments, and blank lines are filtered by the caller. Returns a
    `(name, "name=module:func")` tuple, or None when the entry has no `=` or
    is missing a name, module, or function.

    Legacy entry-point extras (the trailing `[...]`) are parsed and ignored:
    https://packaging.python.org/en/latest/specifications/entry-points/#data-model
    """
    name, sep, target = line.partition("=")
    if not sep:
        return None
    name = name.strip()
    module, _, function_and_extras = target.partition(":")
    function = function_and_extras.split("[")[0].strip()
    module = module.strip()
    if not name or not module or not function:
        return None
    return name, "{}={}:{}".format(name, module, function)

def parse_console_scripts(entry_points):
    """Return canonical console-script entries from entry_points.txt text."""
    console_scripts = {}
    in_console_scripts = False
    for raw_line in entry_points.splitlines():
        line = raw_line.split(";", 1)[0].split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            in_console_scripts = line[1:-1].strip() == "console_scripts"
            continue
        if not in_console_scripts:
            continue
        entry = parse_console_script(line)
        if entry == None:
            continue
        name, normalised = entry
        console_scripts[name] = normalised
    return sorted(console_scripts.values())

def _find_whl_file(repository_ctx, whl_label):
    """Resolve an http_file-style wheel label to the actual .whl path on disk.

    Prefer a label that resolves directly to a wheel. An http_file filegroup
    (`//file:file`) instead resolves to a nonexistent logical path; in that
    case its downloaded wheel is a sibling in the same directory.

    Returns None if no .whl file is found.
    """
    logical_path = repository_ctx.path(whl_label)
    if logical_path.exists and logical_path.basename.endswith(".whl"):
        return logical_path

    parent = logical_path.dirname
    if not parent.exists:
        return None
    candidates = {
        entry.basename: entry
        for entry in parent.readdir()
        if entry.basename.endswith(".whl")
    }
    candidate_names = sorted(candidates.keys())
    if len(candidate_names) == 1:
        return candidates[candidate_names[0]]
    if len(candidate_names) > 1:
        fail("{}: wheel label {} does not resolve directly and its parent contains multiple .whl files: {}".format(
            repository_ctx.name,
            whl_label,
            candidate_names,
        ))
    return None

def _extract_wheel_metadata(repository_ctx, whl_label):
    """Peek inside a wheel to discover top-level names and console scripts.

    Mirrors the rules_js `npm_import` pattern of doing partial archive
    extraction at repo-rule time for metadata, rather than deferring to a
    build-time action (which would leave the info invisible to analysis).

    Reads:
      * `*.dist-info/RECORD` (mandatory per PEP 427) to get top-level names.
      * `*.dist-info/entry_points.txt` (optional) to get `[console_scripts]`.

    Fails if the archive cannot be inspected, so package collision and
    console-script handling never silently depend on host tooling.

    Args:
      repository_ctx: The repo rule context.
      whl_label: A Label pointing at a wheel file (typically an http_file
                 target), passed in via the repo rule's `whl_files`
                 label_list attr so Bazel wires up repo visibility.

    Returns:
      Tuple (whl_basename, layout, console_scripts):
        * whl_basename: basename of the wheel file resolved from whl_label.
        * layout: classified site-packages names and package topology.
        * console_scripts: canonical "name=module:func" entries.
    """
    whl_path = _find_whl_file(repository_ctx, whl_label)
    if whl_path == None:
        fail("{}: could not find wheel for {}".format(repository_ctx.name, whl_label))

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

    # `extract` infers archive type from the extension, so symlink the
    # wheel to a `.zip` name to extract it as the ZIP it is. Drop this once
    # the min Bazel includes .whl detection (bazelbuild/bazel@d9634ca1c143136ef3b02b5ad8876a62368762b5).
    metadata_dir = "_wheel_metadata"
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
    data_directory = metadata_directory[:-len(".dist-info")] + ".data"
    layout = wheel_layout_from_record(record, data_directory)

    # Legacy entry-point extras may be parsed and ignored:
    # https://packaging.python.org/en/latest/specifications/entry-points/#data-model
    console_scripts = parse_console_scripts(entry_points)

    return (
        whl_path.basename,
        layout,
        console_scripts,
    )

def _is_package_initializer(name):
    """Whether a RECORD basename might make its directory a regular package.

    Repository metadata is produced before a target configuration selects one
    Python runtime, so this must be a conservative cross-platform superset, not
    an exact match for the repository host. CPython's FileFinder classifies
    packages by `__init__` plus each configured loader suffix, and CPython 3.14
    derives `.fwork` suffixes from extension suffixes on Apple mobile targets:
    https://github.com/python/cpython/blob/3.14/Lib/importlib/_bootstrap_external.py#L1331-L1385
    https://github.com/python/cpython/blob/3.14/Lib/importlib/_bootstrap_external.py#L1534-L1549

    `__init__.pyi` is additionally package-defining for static tooling even
    though it is not a default CPython source suffix. Overclassification is
    conservative: venv assembly may physically merge an extra directory;
    underclassification could incorrectly split a regular package.
    """
    lower_name = name.lower()
    return (
        lower_name in (
            "__init__.py",
            "__init__.pyc",
            "__init__.pyi",
            "__init__.pyw",
        ) or
        (lower_name.startswith("__init__.") and
         (lower_name.endswith(".so") or
          lower_name.endswith(".pyd") or
          lower_name.endswith(".fwork")))
    )

def wheel_layout_from_record(record, data_directory):
    """Classify the site-packages layout described by a wheel RECORD."""
    top_levels_set = {}
    directory_top_levels = {}
    regular_top_levels = {}
    record_segments = []
    init_dirs = {}
    for line in record.splitlines():
        path = parse_record_path(line)
        if not path:
            continue
        segments = site_packages_segments(path, data_directory)
        if not segments:
            continue

        first_segment = segments[0]

        # Some setuptools-family wheels record scripts outside the install
        # root. These cannot become declared site-packages outputs.
        if (
            not first_segment or
            first_segment in (".", "..") or
            first_segment.startswith("/")
        ):
            continue
        top_levels_set[first_segment] = True
        if len(segments) > 1:
            directory_top_levels[first_segment] = True

        # Single-file modules and directories carrying any conservatively
        # recognized initializer are regular packages, not PEP 420 namespaces.
        if len(segments) == 1 or (
            len(segments) >= 2 and
            _is_package_initializer(segments[1])
        ):
            regular_top_levels[first_segment] = True

        record_segments.append(segments)
        if len(segments) >= 2 and _is_package_initializer(segments[-1]):
            init_dirs["/".join(segments[:-1])] = True

    namespace_top_levels = sorted([
        top_level
        for top_level in top_levels_set
        if top_level not in regular_top_levels and not top_level.endswith(".dist-info")
    ])
    namespace_set = {top_level: True for top_level in namespace_top_levels}

    # Under each namespace, select the shallowest regular-package boundary or
    # concrete file. Nested namespaces recurse until one of those is reached.
    namespace_entries_set = {}
    for segments in record_segments:
        if segments[0] not in namespace_set or len(segments) < 2:
            continue
        for depth in range(2, len(segments) + 1):
            prefix = "/".join(segments[:depth])
            if depth == len(segments) or prefix in init_dirs:
                namespace_entries_set[prefix] = True
                break

    return struct(
        directory_top_levels = sorted(directory_top_levels.keys()),
        namespace_entries = sorted(namespace_entries_set.keys()),
        namespace_top_levels = namespace_top_levels,
        top_levels = sorted(top_levels_set.keys()),
    )

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
    # The sbuild fallback, whose contents are unknowable until build time,
    # is never peeked at here. Its build target carries declared metadata
    # into whl_install; without declared top-levels, consumers preserve the
    # complete wheel through .pth-based resolution.
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
    namespace_entries_by_whl = {}
    namespace_top_levels_by_whl = {}
    console_scripts_by_whl = {}
    for target, whl_file_label in whl_file_labels.items():
        if target not in arm_targets:
            continue
        whl_name, layout, css = _extract_wheel_metadata(
            repository_ctx,
            whl_file_label,
        )
        if layout.top_levels:
            top_levels_by_whl[whl_name] = layout.top_levels
        if layout.directory_top_levels:
            directory_top_levels_by_whl[whl_name] = layout.directory_top_levels
        if layout.namespace_top_levels:
            namespace_top_levels_by_whl[whl_name] = layout.namespace_top_levels
            namespace_entries_by_whl[whl_name] = layout.namespace_entries
        console_scripts_by_whl[whl_name] = css

    install_attrs = """
    src = ":whl",
    compile_pyc = {compile_pyc},
    pyc_invalidation_mode = {pyc_invalidation_mode},
    top_levels = {top_levels},
    directory_top_levels = {directory_top_levels},
    console_scripts = {console_scripts},""".format(
        compile_pyc = compile_pyc_select,
        pyc_invalidation_mode = pyc_invalidation_mode_select,
        top_levels = indent(pprint(top_levels_by_whl), " " * 4).lstrip(),
        directory_top_levels = indent(pprint(directory_top_levels_by_whl), " " * 4).lstrip(),
        console_scripts = indent(pprint(console_scripts_by_whl), " " * 4).lstrip(),
    )

    if namespace_top_levels_by_whl:
        install_attrs += """
    namespace_entries = {namespace_entries},
    namespace_top_levels = {namespace_top_levels},""".format(
            namespace_entries = indent(pprint(namespace_entries_by_whl), " " * 4).lstrip(),
            namespace_top_levels = indent(pprint(namespace_top_levels_by_whl), " " * 4).lstrip(),
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
        # `<project>-<version>.dist-info`, the directory `_extract_wheel_metadata`
        # strips to when extracting RECORD/entry_points.txt out of the wheel.
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
