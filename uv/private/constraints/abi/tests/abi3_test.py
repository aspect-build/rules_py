"""Ordinary stable-ABI wheels must not match free-threaded interpreters."""

import importlib.util
import os
import sysconfig

freethreaded = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
assert freethreaded == (os.environ["EXPECT_ABI3T"] == "1"), freethreaded

for tag in ["abi3", "abi3t"]:
    matched = importlib.util.find_spec(tag) is not None
    assert matched == (os.environ["EXPECT_" + tag.upper()] == "1"), f"{tag} matched={matched}"
