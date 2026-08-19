"""Build a runtime import index from declared Bazel artifact paths.

Input C/H/R describe covered, known-layout, and raw roots; S/T/L/Q/A/B describe
source/symlink paths; W records virtual wheel projections and their owners.
Output I/D retain wheels, R preserves root order, and P/N map imports/namespaces
to roots. Only artifact paths are consumed; source contents are not action inputs.
"""

import sys
from collections import defaultdict
from pathlib import Path


def _top_level(segment: str, directory: bool) -> str | None:
    if not directory:
        if segment.endswith((".py", ".pyc")):
            segment = segment.rsplit(".", 1)[0]
        elif segment.endswith((".so", ".pyd")):
            segment = segment.split(".", 1)[0]
        else:
            return None
    return segment if segment.isidentifier() else None


def _first_party_path(kind: str, short_path: str, workspace_prefix: str) -> str | None:
    if short_path.startswith(("../", "/")):
        return None
    if kind in {"A", "B"}:
        return short_path if short_path.startswith(workspace_prefix) else None
    if kind in {"L", "Q"} and short_path.startswith(workspace_prefix):
        return short_path
    return workspace_prefix + short_path.removeprefix("./")


def generate(
    *, records_path: str, workspace: str, escape: str, venv_escape: str
) -> tuple[str, str]:
    workspace_prefix = workspace + "/"
    import_roots = []
    wheel_root_coverage = {}
    source_rows = []
    records = []
    wheel_imports = defaultdict(dict)
    with Path(records_path).open(encoding="utf-8") as record_file:
        for line in record_file:
            row = line.rstrip("\r\n")
            kind, separator, value = row.partition("\t")
            if not separator:
                raise ValueError(f"Invalid import index record: {row!r}")
            if kind in {"S", "T", "L", "Q", "A", "B"}:
                source = _first_party_path(kind, value, workspace_prefix)
                if source is not None:
                    source_rows.append((source, kind in {"T", "Q", "B"}))
            elif kind == "R":
                import_roots.append(value)
            elif kind in {"C", "H"}:
                wheel_root_coverage[value] = kind == "C"
            elif kind == "W":
                entry, _, site_packages = value.partition("\t")
                root = escape + "/" + site_packages
                if "/" not in entry and entry.endswith((".dist-info", ".egg-info")):
                    records.append("D\t" + entry + "\t" + root)
                    continue
                name = entry.split("/", 1)[0]
                if name.endswith((".py", ".pyc")):
                    name = name.rsplit(".", 1)[0]
                elif name.endswith((".so", ".pyd")):
                    name = name.split(".", 1)[0]
                wheel_imports[name][root] = None
            else:
                raise ValueError(f"Invalid import index record: {row!r}")

    records = [
        "I\t" + name + "\t" + "\t".join(roots) for name, roots in wheel_imports.items()
    ] + records

    roots = [("K", "")]
    opaque_sources = {source for source, is_tree in source_rows if is_tree}
    opaque_prefixes = tuple(path + "/" for path in opaque_sources)
    trie = {}
    for root in import_roots:
        if wheel_root_coverage.get(root):
            continue
        segments = root.split("/")
        if root.endswith("site-packages") and root not in wheel_root_coverage:
            kind = "X"
        elif root in opaque_sources or root.startswith(opaque_prefixes):
            kind = "K"
        elif root.startswith(workspace_prefix) and "site-packages" not in segments:
            kind = "F"
            node = trie
            for segment in segments:
                node = node.setdefault(segment, {})
            # Deduplicated import roots give each trie terminal one owner.
            node[None] = len(roots)
        else:
            kind = "K"
        roots.append((kind, root))

    claims = defaultdict(set)
    namespace_rows = defaultdict(list)
    for source, is_tree in source_rows:
        segments = source.split("/")
        node = trie
        for offset, segment in enumerate(segments):
            position = node.get(None)
            if position is not None:
                name = _top_level(segment, is_tree or offset + 1 < len(segments))
                if name is not None:
                    claims[name].add(position)
                    namespace_rows[name].append((source, is_tree, position, offset))
            node = node.get(segment)
            if node is None:
                break

    claimed_positions = set().union(*claims.values())

    del source_rows
    namespace_claims = defaultdict(set)
    regular_packages = set()
    opaque_namespaces = set()
    for top_level, rows in namespace_rows.items():
        if len(claims[top_level]) < 2:
            continue
        for source, is_tree, position, offset in rows:
            segments = source.split("/")
            package = top_level
            for child_offset in range(offset + 1, len(segments)):
                directory = is_tree or child_offset + 1 < len(segments)
                child = _top_level(segments[child_offset], directory)
                if child is None:
                    break
                if child == "__init__" and not directory:
                    regular_packages.add(package)
                    break
                package += "." + child
                namespace_claims[package].add(position)
            if is_tree:
                opaque_namespaces.add(package)

    pth = [
        "import os, sys; _venv_bin = os.path.dirname(sys.executable); "
        '_path = os.environ.get("PATH", ""); '
        'os.environ["PATH"] = _path if _venv_bin in _path.split(os.pathsep) '
        "else _venv_bin + os.pathsep + _path; del _venv_bin, _path",
        "import _aspect_rules_py_import_index",
    ]
    for position, (kind, root) in enumerate(roots):
        # Unclaimed roots retain their physical sys.path entry.
        if kind == "F" and position not in claimed_positions:
            kind = "K"
        relative_root = escape if not root else escape + "/" + root
        index_kind = "K" if kind == "X" else kind
        records.append("R\t" + index_kind + "\t" + relative_root)
        if kind == "X":
            # site supplies known_paths while executing .pth lines; reuse it to avoid rescans.
            pth.append(
                "import os, sys, site; "
                "site.addsitedir(os.path.normpath(os.path.join("
                f'sys.prefix, "{venv_escape}", "{root}")), vars().get("known_paths"))'
            )
        elif kind == "K":
            pth.append(relative_root)

    for name, positions in sorted(claims.items()):
        records.append("P\t" + name + "\t" + "\t".join(map(str, sorted(positions))))

    opaque_namespace_prefixes = tuple(name + "." for name in opaque_namespaces)
    for name, positions in sorted(namespace_claims.items()):
        parent = name.rpartition(".")[0]
        parent_positions = namespace_claims.get(parent) or claims.get(parent)
        if (
            len(parent_positions) < 2
            or parent in regular_packages
            or parent in opaque_namespaces
            or parent.startswith(opaque_namespace_prefixes)
        ):
            continue
        records.append("N\t" + name + "\t" + "\t".join(map(str, sorted(positions))))

    return "\n".join(records) + "\n", "\n".join(pth) + "\n"


if __name__ == "__main__":
    workspace, escape, venv_escape, index_file, pth_file = sys.argv[1:6]
    helper_source, helper_output, records_path = sys.argv[6:]
    index, pth = generate(
        records_path=records_path,
        workspace=workspace,
        escape=escape,
        venv_escape=venv_escape,
    )
    Path(index_file).write_text(index, encoding="utf-8")
    Path(pth_file).write_text(pth, encoding="utf-8")
    Path(helper_output).write_bytes(Path(helper_source).read_bytes())
