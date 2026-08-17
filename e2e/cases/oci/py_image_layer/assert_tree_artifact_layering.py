"""Assert a grouped TreeArtifact is absent from the default source tar."""

import sys
import tarfile


def _members(path: str) -> list[str]:
    with tarfile.open(path, "r:*") as archive:
        return archive.getnames()


def main() -> int:
    tars = sys.argv[1:]
    default_tar = next(path for path in tars if path.endswith("_default.tar.gz"))
    group_tar = next(path for path in tars if path.endswith("_tree_data.tar.gz"))
    for payload in ("tree_payload.txt", "tree payload.txt", "tree_group_data_direct.txt"):
        if any(name.endswith(payload) for name in _members(default_tar)):
            print("FAIL: grouped payload leaked into the default source layer: " + payload, file=sys.stderr)
            return 1
        if not any(name.endswith(payload) for name in _members(group_tar)):
            print("FAIL: grouped payload is missing from its owning layer: " + payload, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
