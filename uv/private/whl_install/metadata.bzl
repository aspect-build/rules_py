"""Wheel metadata extraction.

Peeks inside a wheel to discover the top-level names it installs AND its
`[console_scripts]` entry points, then derives the namespace / regular-root /
native-root layout `PyWheelsInfo` needs. Mirrors the rules_js `npm_import`
pattern of doing partial archive extraction at repo-rule time, rather than
deferring to a build-time action (which would leave the info invisible to
analysis).

Runs in the per-wheel `whl_dist` repo, so only the wheel actually selected for
a configuration is ever fetched and inspected — sibling platform wheels are
never downloaded.
"""

load("//uv/private:normalize_name.bzl", "normalize_name")
load("//uv/private:parse_whl_name.bzl", "parse_whl_name")

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

def data_scheme_segments(path, data_directory):
    """Map a RECORD path under `.data/data/` to its prefix-relative segments.

    PEP 427's `data` category installs into `sys.prefix` (e.g. `share/`,
    `etc/`), the tree venv assembly projects for issue #1366. Returns `None`
    for anything that isn't a `.data/data/` file.
    """
    segments = path.split("/")
    if len(segments) < 3 or segments[0] != data_directory or segments[1] != "data":
        return None
    return segments[2:]

def data_segments_contained(segments):
    """True when every prefix-relative segment stays inside the venv prefix.

    Data paths become `ctx.actions.declare_symlink` outputs under the prefix, so
    an empty, `.`, or `..` component must not be projected. An absolute path is
    caught by the same test: it splits to a leading empty segment.

    Containment only: a contained path that lands on a venv-owned prefix root is
    still reported here, so `_resolve_data_files` stays the single place that
    applies the `package_collisions` policy to it.
    """
    return all([
        seg and seg not in (".", "..")
        for seg in segments
    ])

def parse_record(record, data_directory):
    """Route every RECORD entry to site-packages segments or a prefix data path.

    One pass: each line is parsed once and dispatched on its PEP 427 category,
    which are mutually exclusive. Split out of `extract_install_metadata` so the
    RECORD-to-metadata mapping is testable without a repo context.

    Site-packages entries that escape the install root are dropped — some wheels
    (setuptools-family) emit `../../bin/foo` for scripts, and `..`/`.`/absolute/
    empty first segments would make `ctx.actions.declare_symlink` synthesize
    phantom parent outputs and collide.

    Reserved prefix paths (`bin/python`, `pyvenv.cfg`, site-packages) stay in
    `data_files` like any other: `_resolve_data_files` owns the collision policy
    for them.

    Args:
      record: RECORD's contents, or `None` when the wheel ships none.
      data_directory: The `<project>-<version>.data` directory name.

    Returns:
      A struct of `record_segments` (list of segment lists, RECORD order) and
      `data_files` (sorted prefix-relative paths).
    """
    record_segments = []
    data_files = []
    for line in record.splitlines() if record else []:
        path = parse_record_path(line)
        if not path:
            continue
        data_segments = data_scheme_segments(path, data_directory)
        if data_segments != None:
            if data_segments_contained(data_segments):
                data_files.append("/".join(data_segments))
        else:
            segments = site_packages_segments(path, data_directory)
            if not segments:
                continue
            first_segment = segments[0]
            if not first_segment or first_segment in (".", "..") or first_segment.startswith("/"):
                continue
            record_segments.append(segments)
    return struct(
        record_segments = record_segments,
        data_files = sorted(data_files),
    )

def native_roots_for_segments(segments, collision_roots = ()):
    """Return collision roots whose relocation can break a native file.

    A native library resolves sibling assets from its on-disk origin. Every
    top-level directory containing one is collision-relevant, as is any
    RECORD-derived namespace directory or regular root beneath a namespace
    that contains it.
    Top-level native modules have no directory root and never participate in
    directory merges.
    """
    if len(segments) < 2:
        return []
    filename = segments[-1]
    _, so_separator, so_version = filename.partition(".so.")
    if not (
        filename.endswith(".so") or
        (so_separator and so_version and so_version[0] in "0123456789") or
        filename.endswith(".pyd") or
        filename.endswith(".dylib") or
        filename.endswith(".dll")
    ):
        return []
    path = "/".join(segments)
    roots = [segments[0]]
    for root in collision_roots:
        if path.startswith(root + "/"):
            roots.append(root)
    return roots

# Keep parsing, matching, and cache-to-source matching in sync with
# py/tools/unpack/{exclude_glob.py,unpack.py} and their shared test vectors.
# `whl_dist` extraction stays exclude-agnostic (the per-wheel repo never sees
# a per-package exclude_glob); `whl_install` applies these at analysis time to
# the selected wheel's layout so the advertised surface matches the install
# action's filtered tree.
def parse_exclude_glob(value):
    """Return the validated segments of a site-packages-relative glob."""
    parts = value.split("/")
    if not value or "\\" in value or any([
        not part or
        part in (".", "..") or
        any([character in part for character in (":", "?", "[", "]")]) or
        ("**" in part and part != "**")
        for part in parts
    ]):
        fail("invalid wheel exclude glob: {}".format(value))
    return parts

def _exclude_glob_chunk_matches(value, pattern):
    parts = pattern.split("*")
    if len(parts) == 1:
        return value == pattern
    if not value.startswith(parts[0]) or not value.endswith(parts[-1]):
        return False
    if len(parts[0]) + len(parts[-1]) > len(value):
        return False
    value = value[len(parts[0]):]
    if parts[-1]:
        value = value[:-len(parts[-1])]
    for part in parts[1:-1]:
        index = value.find(part)
        if index < 0:
            return False
        value = value[index + len(part):]
    return True

def exclude_glob_matches(path, pattern):
    """Return whether a parsed glob excludes path or one of its parents."""
    pattern = pattern + ["**"]
    states = {0: True}
    for segment in path:
        for index in range(len(pattern)):
            if index in states and pattern[index] == "**":
                states[index + 1] = True
        next_states = {}
        for index in range(len(pattern)):
            if index not in states:
                continue
            if pattern[index] == "**":
                next_states[index] = True
            elif _exclude_glob_chunk_matches(segment, pattern[index]):
                next_states[index + 1] = True
        states = next_states
    for index in range(len(pattern)):
        if index in states and pattern[index] == "**":
            states[index + 1] = True
    return len(pattern) in states

def cache_source_path(path):
    """Return the source segments a `.pyc` is reached through, or None.

    Cache tags are stripped right to left, so a dotted source such as
    `mod.v1.py` resolves from `mod.v1.cpython-311.pyc`. Keep in sync with
    cache_source_path in py/tools/unpack/unpack.py and the shared test vectors.
    """
    if not path or not path[-1].endswith(".pyc"):
        return None
    if len(path) < 2 or path[-2] != "__pycache__":
        return path[:-1] + [path[-1][:-len(".pyc")] + ".py"]
    stem, separator, tag = path[-1][:-len(".pyc")].rpartition(".")
    if tag.startswith("opt-"):
        if not tag[len("opt-"):]:
            return None
        stem, separator, tag = stem.rpartition(".")
    if not stem or not separator or not tag:
        return None
    return path[:-2] + [stem + ".py"]

def record_path_excluded(path, patterns):
    """Return whether installation removes a RECORD path or its source."""
    source = cache_source_path(path)
    return any([
        exclude_glob_matches(path, pattern) or
        (source != None and exclude_glob_matches(source, pattern))
        for pattern in patterns
    ])

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

def _canonical_number(text):
    """A PEP 440 numeric component: digits, no leading zeros."""
    return text.isdigit() and (text == "0" or not text.startswith("0"))

def _canonical_pre_release(pre):
    """A PEP 440 pre-release segment: `a`, `b` or `rc` joined to its number."""
    for tag in ("a", "b", "rc"):
        if pre.startswith(tag):
            return _canonical_number(pre[len(tag):])
    return False

def canonical_version(version):
    """True when `version` is already spelled in PEP 440 canonical form.

    Only a canonical version reaches the `.dist-info` name unchanged. Every
    other spelling -- `v1.0`, `1.0c1`, `1.0_rc1`, `1.0RC1`, `1.00` -- is
    rewritten by the backend, so the directory name has to come from the
    archive. An epoch's `!` is URL-encoded in a wheel filename and so never
    canonical here.
    """
    public, plus, local = version.partition("+")
    if plus:
        for segment in local.split("."):
            if not segment or not segment.isalnum() or segment != segment.lower():
                return False

            # An all-digit local segment compares numerically, so a leading zero
            # is dropped: `+01` and `+ubuntu.04` become `+1` and `+ubuntu.4`.
            if segment.isdigit() and not _canonical_number(segment):
                return False

    epoch, bang, rest = public.partition("!")
    if bang:
        # A zero epoch is dropped entirely: `0!1.0` normalizes to `1.0`.
        if epoch == "0" or not _canonical_number(epoch):
            return False
    else:
        rest = epoch

    rest, dot_dev, dev = rest.partition(".dev")
    if dot_dev and not _canonical_number(dev):
        return False
    rest, dot_post, post = rest.partition(".post")
    if dot_post and not _canonical_number(post):
        return False

    # The release segment is digits and dots, so the first other character
    # opens the pre-release tag.
    for index in range(len(rest)):
        if not (rest[index].isdigit() or rest[index] == "."):
            if not _canonical_pre_release(rest[index:]):
                return False
            rest = rest[:index]
            break

    if not rest:
        return False
    return all([_canonical_number(segment) for segment in rest.split(".")])

def metadata_directory_hint(basename):
    """The `<project>-<version>.dist-info` a wheel filename implies.

    Args:
      basename: The wheel's file name.

    Returns:
      A struct of the implied `directory` and whether it is `authoritative`:
      an already-normalized filename pins the archive member, anything else is
      a guess a differently-escaping backend can contradict (#1394).
    """
    whl_name = parse_whl_name(basename)

    # `+` is URL-encoded in the filename but literal in the member; the build
    # tag never appears in dist-info and parse_whl_name already dropped it.
    version = whl_name.version.replace("%2B", "+").replace("%2b", "+")
    return struct(
        directory = "{}-{}.dist-info".format(whl_name.project, version),
        authoritative = (
            whl_name.project == normalize_name(whl_name.project) and
            canonical_version(version)
        ),
    )

def data_directory_for(metadata_directory):
    """The `.data` sibling of a wheel's `.dist-info` directory.

    Both carry the same stem, and RECORD spells its `.data` paths with the one
    the archive shipped, not the one the filename implies (#1394).
    """
    return metadata_directory[:-len(".dist-info")] + ".data"

def _discover_metadata_directory(rctx, root, whl_path, expected):
    """Pick the `.dist-info` directory out of a fully extracted wheel."""
    candidates = sorted([
        entry.basename
        for entry in root.readdir()
        if entry.basename.endswith(".dist-info") and entry.is_dir
    ])
    if len(candidates) != 1:
        fail("{}: wheel {} has {} .dist-info directories ({}), expected {}".format(
            rctx.name,
            whl_path,
            len(candidates),
            ", ".join(candidates) if candidates else "none",
            expected,
        ))
    return candidates[0]

def _read_dist_info(rctx, whl_path, basename):
    """Read RECORD and entry_points.txt out of the wheel's `.dist-info`.

    Returns (record_text, entry_points_text, metadata_directory). The returned
    directory is the one the archive actually carries, which is not always the
    one the filename implies. entry_points_text is empty when the wheel ships
    no `entry_points.txt` (normal for libraries without scripts).
    """
    hint = metadata_directory_hint(basename)
    metadata_directory = hint.directory

    metadata_dir = "_wheel_metadata"
    rctx.delete(metadata_dir)

    # An authoritative name is stripped directly, leaving only the `.dist-info`
    # on disk. A guess can't be: `strip_prefix` hard-fails on a miss, so the
    # whole wheel inflates instead (a 53MB SimpleITK wheel writes 278MB) and
    # `_discover_metadata_directory` reads the real name off the result.
    rctx.extract(
        archive = whl_path,
        output = metadata_dir,
        strip_prefix = metadata_directory if hint.authoritative else "",
    )
    metadata_path = rctx.path(metadata_dir)
    if not hint.authoritative:
        metadata_directory = _discover_metadata_directory(rctx, metadata_path, whl_path, metadata_directory)
        metadata_path = metadata_path.get_child(metadata_directory)
    record_path = metadata_path.get_child("RECORD")
    if not record_path.exists:
        fail("{}: wheel {} has no {}/RECORD".format(rctx.name, whl_path, metadata_directory))
    record = rctx.read(record_path)
    entry_points = ""
    entry_points_path = metadata_path.get_child("entry_points.txt")
    if entry_points_path.exists:
        entry_points = rctx.read(entry_points_path)
    rctx.delete(metadata_dir)
    return record, entry_points, metadata_directory

def derive_layout(record_segments):
    """Derive the site-packages layout from filtered RECORD segment lists.

    `record_segments` are site-packages-relative paths (install-root escapes
    already dropped). Run once at extraction, and again at analysis time (in
    `whl_install`) over the segments that survive `exclude_glob` — so removing
    an `__init__.py`, or the last file under a top-level, reclassifies
    namespace/regular and drops stale entries instead of leaving the advertised
    topology out of sync with the installed tree.
    """

    # First path segment = top-level name. Track which top-levels have a direct
    # `<toplevel>/__init__.py` (regular packages); the complement are PEP 420
    # namespaces. Also record the directory skeleton, which dirs hold an
    # `__init__.py`, and which files are native.
    top_levels_set = {}
    regular_top_levels = {}
    dirs_set = {}
    init_dirs = {}
    native_segments = []
    for segments in record_segments:
        first_segment = segments[0]
        top_levels_set[first_segment] = True
        if len(segments) == 1 or (len(segments) >= 2 and segments[1] == "__init__.py"):
            regular_top_levels[first_segment] = True
        if native_roots_for_segments(segments):
            native_segments.append(segments)
        for i in range(1, len(segments)):
            dirs_set["/".join(segments[:i])] = True
        if len(segments) >= 2 and segments[-1] == "__init__.py":
            init_dirs["/".join(segments[:-1])] = True

    # Namespace entries: for each path under a namespace top-level, descend to
    # the shallowest concrete prefix — a dir with a direct `__init__.py`, or the
    # file itself. Nested namespaces (`google/cloud/storage/…`) recurse.
    namespace_entries_set = {}
    for segments in record_segments:
        if segments[0] in regular_top_levels or segments[0].endswith(".dist-info"):
            continue
        if len(segments) < 2:
            continue
        for depth in range(2, len(segments) + 1):
            prefix = "/".join(segments[:depth])
            if depth == len(segments) or prefix in init_dirs:
                namespace_entries_set[prefix] = True
                break

    top_level_dirs = sorted([
        tl
        for tl in top_levels_set
        if (tl in dirs_set and
            not tl.endswith(".dist-info") and
            not tl.endswith(".egg-info"))
    ])

    namespaces = sorted([
        tl
        for tl in top_levels_set
        if (tl not in regular_top_levels and
            not tl.endswith(".dist-info") and
            not tl.endswith(".egg-info"))
    ])
    namespace_set = {tl: True for tl in namespaces}

    namespace_entries = sorted([
        entry
        for entry in namespace_entries_set
        if entry.split("/")[0] in namespace_set
    ])

    namespace_dirs, regular_roots = _namespace_dirs_and_roots(dirs_set, init_dirs, namespace_set)

    native_roots = {}
    for segments in native_segments:
        for root in native_roots_for_segments(segments, namespace_dirs + regular_roots):
            native_roots[root] = True

    return struct(
        top_levels = sorted(top_levels_set.keys()),
        top_level_dirs = top_level_dirs,
        namespace_top_levels = namespaces,
        namespace_entries = namespace_entries,
        namespace_dirs = namespace_dirs,
        regular_roots = regular_roots,
        native_roots = sorted(native_roots.keys()),
    )

def extract_install_metadata(rctx, whl_path, basename):
    """Peek inside a wheel and derive the layout `PyWheelsInfo` consumes.

    Reads:
      * `*.dist-info/RECORD` (mandatory per PEP 427) to get top-level names.
      * `*.dist-info/entry_points.txt` (optional) to get `[console_scripts]`.

    Fails if the archive cannot be inspected, so package collision and
    console-script handling never silently depend on host tooling.

    Args:
      rctx: The repo rule context.
      whl_path: A resolved `rctx.path` to the wheel on disk.
      basename: The wheel's file name, which implies the `.dist-info` directory
        holding RECORD/entry_points.txt.

    Returns:
      A struct of sorted `list[str]` fields ready to pass straight through as
      the `whl_dist` build rule's attrs: `top_levels`, `top_level_dirs`,
      `namespace_top_levels`, `namespace_entries`, `namespace_dirs`,
      `regular_roots`, `native_roots`, `console_scripts`, `data_files`.
    """
    record, entry_points, metadata_directory = _read_dist_info(rctx, whl_path, basename)
    data_directory = data_directory_for(metadata_directory)

    # RECORD: authoritative list of every installed file, split in one pass into
    # the site-packages segments the layout derives from and the prefix data
    # paths venv assembly projects.
    parsed = parse_record(record, data_directory)
    record_segments = parsed.record_segments

    # entry_points.txt: INI-style file. Only `[console_scripts]` interests
    # us — pip/uv synthesize executables under `bin/<name>` from those at
    # install time. Missing file is normal (lots of libs have no scripts).
    # These live under bin/, not site-packages, so exclude_glob never affects
    # them and they are derived once here.
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

    # A wheel's RECORD always lists at least its `.dist-info`, so a prebuilt
    # wheel's top_levels is never empty (empty stays reserved for source-built
    # wheels of unknown layout). `record_paths` is preserved so whl_install can
    # re-derive the layout after applying exclude_glob.
    layout = derive_layout(record_segments)
    return struct(
        top_levels = layout.top_levels,
        top_level_dirs = layout.top_level_dirs,
        namespace_top_levels = layout.namespace_top_levels,
        namespace_entries = layout.namespace_entries,
        namespace_dirs = layout.namespace_dirs,
        regular_roots = layout.regular_roots,
        native_roots = layout.native_roots,
        console_scripts = sorted(console_scripts.values()),
        record_paths = ["/".join(segments) for segments in record_segments],
        data_files = parsed.data_files,
    )
