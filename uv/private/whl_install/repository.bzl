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
    if len(segments) < 3 or segments[1] not in ("purelib", "platlib"):
        return []
    return segments[2:]

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

    Fails if the archive cannot be inspected, so package collision and
    console-script handling never silently depend on host tooling.

    Args:
      repository_ctx: The repo rule context.
      whl_label: A Label pointing at a wheel file (typically an http_file
                 target), passed in via the repo rule's `whl_files`
                 label_list attr so Bazel wires up repo visibility.

    Returns:
      Tuple (top_levels_set, regular_top_levels_set, console_scripts_set,
             namespace_entries_set, dirs_set, init_dirs_set):
        * top_levels_set: dict[name → True] — all first-path-segment
          names in RECORD (excluding `*.data/` staging entries).
        * regular_top_levels_set: subset that had an `__init__.py` at
          depth 1, i.e. regular packages. Its complement (within
          top_levels_set, minus `.dist-info/`) is the PEP 420 namespace
          set for this wheel.
        * console_scripts_set: dict[script_name → "name=module:func"].
        * namespace_entries_set: dict[path → True] — for each top-level
          that looks like a PEP 420 namespace in THIS wheel, the
          `/`-joined paths of the concrete entries beneath it: the
          shallowest directory holding a direct `__init__.py` (recursing
          through nested namespace dirs like `google/cloud/`), or the
          file itself for plain modules / data files. Lets venv assembly
          materialise a merged namespace dir out of per-entry symlinks.
        * dirs_set: dict[path → True] — every directory implied by a
          RECORD entry, as a `/`-joined relative path.
        * init_dirs_set: dict[path → True] — subset of dirs_set that
          directly contain an `__init__.py` (regular packages). Powers
          the per-wheel namespace_dirs / regular_roots derivation, which
          venv assembly uses to detect regular packages spanning wheels.
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

    # RECORD: authoritative list of every installed file. First path segment
    # = top-level name after translating wheel install-scheme paths.
    top_levels_set = {}

    # Tracks which top-levels contain a direct `<toplevel>/__init__.py` —
    # i.e., are regular packages. The complement (top_levels that never
    # appear with an `__init__.py` at depth 1) are PEP 420 namespace
    # packages that expect to be merged across wheels.
    regular_top_levels = {}

    # Raw material for the namespace derivations below: every kept RECORD
    # path (as segment lists) plus the full directory skeleton and the set
    # of directories that hold a direct `__init__.py` at any depth.
    record_segments = []
    dirs_set = {}
    init_dirs = {}
    if record:
        for line in record.splitlines():
            path = parse_record_path(line)
            if not path:
                continue
            segments = site_packages_segments(path, data_directory)
            if not segments:
                continue

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

            # Single-file modules (e.g. `six.py` at top level) aren't
            # namespace packages — treat them as regular.
            if len(segments) == 1 or (len(segments) >= 2 and segments[1] == "__init__.py"):
                regular_top_levels[first_segment] = True

            record_segments.append(segments)

            # Record every directory along the path, and which of them
            # directly contain an `__init__.py`.
            for i in range(1, len(segments)):
                dirs_set["/".join(segments[:i])] = True
            if len(segments) >= 2 and segments[-1] == "__init__.py":
                init_dirs["/".join(segments[:-1])] = True

    # Namespace entries: for each path under a (per-this-wheel) namespace
    # top-level, descend until hitting the shallowest concrete prefix — a
    # directory with a direct `__init__.py`, or the file itself when no
    # such directory exists on the way down (plain modules like
    # `jaraco/context.py`, or bare data files). Nested namespaces
    # (`google/cloud/storage/…`) recurse naturally: `google/cloud` has no
    # `__init__.py`, so the walk continues to `google/cloud/storage`.
    # Entries for top-levels that turn out regular are filtered out here.
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

            # Normalise to "name=module:func" so downstream parsing is trivial.
            entry = parse_console_script(line)
            if entry == None:
                continue
            name, normalised = entry
            console_scripts[name] = normalised

    return whl_path.basename, top_levels_set, regular_top_levels, console_scripts, namespace_entries, dirs_set, init_dirs

def _namespace_dirs_and_roots(dirs_set, init_dirs, namespace_top_levels_set):
    """Split a wheel's directory skeleton into the implicit-namespace dirs
    and the minimal regular-package roots, restricted to the wheel's
    namespace top-levels.

    Walking from the top, content is an implicit-namespace portion until
    the first directory carrying an `__init__.py` — that directory is a
    "regular root" and everything below it is interior to a regular
    package.

      * namespace_dirs: the implicit-namespace skeleton, minus the depth-1
        entries already covered by namespace_top_levels
        (azure-core → []; azure-core-tracing-opentelemetry →
        ["azure/core", "azure/core/tracing", "azure/core/tracing/ext"]).
      * regular_roots: the minimal regular-package dirs (azure-core →
        ["azure/core"]).

    venv assembly cross-references these across wheels: a regular root
    appearing in another wheel's namespace skeleton means a regular
    package SPANS wheels — Python's namespace machinery cannot merge that,
    so the subtree must be physically merged. Dirs under regular
    top-levels are skipped (handled by the top-level collision policy).
    """
    namespace_dirs = []
    regular_roots = []
    for d in sorted(dirs_set.keys()):
        segments = d.split("/")
        if segments[0] not in namespace_top_levels_set:
            continue
        boundary = None
        for i in range(len(segments)):
            prefix = "/".join(segments[:i + 1])
            if prefix in init_dirs:
                boundary = prefix
                break
        if boundary == None:
            # Depth-1 entries are redundant with namespace_top_levels
            # (regular roots are always depth >= 2, so the cross-wheel
            # scan never consults them) — dropping them keeps wheels with
            # only a `<pkg>.libs/` shared-library dir attr-free.
            if len(segments) >= 2:
                namespace_dirs.append(d)
        elif boundary == d:
            regular_roots.append(d)
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
    # The sbuild fallback, whose contents are unknowable until build time, is
    # never peeked at here. Its PyWheelsInfo record has unknown metadata, so
    # venv consumers use .pth-based resolution while image layering still
    # retains the installed wheel tree.
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
    namespace_top_levels_by_whl = {}
    namespace_entries_by_whl = {}
    namespace_dirs_by_whl = {}
    regular_roots_by_whl = {}
    console_scripts_by_whl = {}
    for target, whl_file_label in whl_file_labels.items():
        if target not in arm_targets:
            continue
        whl_name, tls, regular, css, ns_entries, dirs_set, init_dirs = _extract_wheel_metadata(
            repository_ctx,
            whl_file_label,
        )
        if tls:
            top_levels_by_whl[whl_name] = sorted(tls.keys())

            # A top-level counts as a PEP 420 namespace for this wheel if
            # its RECORD shows no `<toplevel>/__init__.py` at depth 1.
            namespaces = sorted([
                tl
                for tl in tls
                if tl not in regular and not tl.endswith(".dist-info")
            ])
            if namespaces:
                namespace_top_levels_by_whl[whl_name] = namespaces
                namespace_set = {tl: True for tl in namespaces}

                # Concrete entries beneath this wheel's namespace
                # top-levels (`jaraco/functools`) — for the per-entry
                # symlink merge that makes the namespace mypy/pyright
                # visible.
                entries = sorted([
                    entry
                    for entry in ns_entries
                    if entry.split("/")[0] in namespace_set
                ])
                if entries:
                    namespace_entries_by_whl[whl_name] = entries

                # Implicit-namespace dir skeleton + minimal regular roots
                # under this wheel's namespace top-levels — for detecting
                # a regular package that spans wheels (azure-core case).
                ndirs, rroots = _namespace_dirs_and_roots(dirs_set, init_dirs, namespace_set)
                if ndirs:
                    namespace_dirs_by_whl[whl_name] = ndirs
                if rroots:
                    regular_roots_by_whl[whl_name] = rroots
        if css:
            console_scripts_by_whl[whl_name] = sorted(css.values())

    install_attrs = """
    src = ":whl",
    compile_pyc = {compile_pyc},
    pyc_invalidation_mode = {pyc_invalidation_mode},
    top_levels = {top_levels},
    namespace_top_levels = {namespace_top_levels},
    console_scripts = {console_scripts},""".format(
        compile_pyc = compile_pyc_select,
        pyc_invalidation_mode = pyc_invalidation_mode_select,
        top_levels = indent(pprint(top_levels_by_whl), " " * 4).lstrip(),
        namespace_top_levels = indent(pprint(namespace_top_levels_by_whl), " " * 4).lstrip(),
        console_scripts = indent(pprint(console_scripts_by_whl), " " * 4).lstrip(),
    )

    # Only emitted for wheels that contribute to a namespace — keeps the
    # generated BUILD files (and their e2e snapshots) unchanged for the
    # common regular-top-level-only case.
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
