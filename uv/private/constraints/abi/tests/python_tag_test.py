"""CPython wheel tags must match the interpreter minor when the ABI is none."""

import importlib.util
import os

for tag in ["cp312_none", "cp313_none", "py312_none"]:
    matched = importlib.util.find_spec(tag) is not None
    should_match = os.environ["EXPECT_" + tag.upper()] == "1"
    assert matched == should_match, f"{tag} matched={matched}"
