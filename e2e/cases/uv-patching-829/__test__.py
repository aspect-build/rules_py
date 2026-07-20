#!/usr/bin/env python3

"""Test that post-install patches are applied to cowsay and tracked in RECORD."""

import csv
import hashlib
from base64 import urlsafe_b64encode
from pathlib import Path

import cowsay

# Verify the post-install patch modified __init__.py.
assert hasattr(cowsay, "PATCHED_POST_INSTALL"), (
    "Post-install patch was not applied: cowsay.PATCHED_POST_INSTALL is missing"
)
assert cowsay.PATCHED_POST_INSTALL is True
print("post_install patch: OK")

site_packages = Path(cowsay.__file__).parent.parent
record_path = next(site_packages.glob("cowsay-*.dist-info/RECORD"))
with record_path.open(newline="", encoding="utf-8") as record:
    rows = {path: (digest, size) for path, digest, size in csv.reader(record)}


def _assert_record_matches_disk(relative):
    content = (site_packages / relative).read_bytes()
    digest = urlsafe_b64encode(hashlib.sha256(content).digest()).decode().rstrip("=")
    assert rows[relative] == (f"sha256={digest}", str(len(content))), relative


# A patch that rewrites a shipped file must update that file's RECORD entry.
_assert_record_matches_disk("cowsay/__init__.py")
print("post_install RECORD (modified): OK")

# A patch that adds a file must add it to RECORD with the installed bytes.
assert (site_packages / "cowsay" / "patched_added.py").is_file()
_assert_record_matches_disk("cowsay/patched_added.py")
print("post_install RECORD (added): OK")

# A patch that removes a file must leave RECORD reflecting disk. GNU patch
# deletes the file (absent from RECORD); Apple/BSD patch truncates it to empty
# (present with the empty-file digest). Either way RECORD must match disk.
deleted = "cowsay/tests/test_api.py"
if (site_packages / deleted).exists():
    _assert_record_matches_disk(deleted)
else:
    assert deleted not in rows
print("post_install RECORD (deleted): OK")

# Verify cowsay still works after patching.
output = cowsay.get_output_string("cow", "patches work!")
assert "patches work!" in output
print("cowsay functional: OK")

print("All patching tests passed.")
