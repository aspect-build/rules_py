"""Ordinary stable-ABI wheels must not match free-threaded interpreters."""

import os
import sysconfig

freethreaded = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
assert freethreaded == (os.environ["EXPECT_ABI3T"] == "1"), freethreaded

for tag in ["ABI3", "ABI3T"]:
    assert os.environ[tag] == os.environ["EXPECT_" + tag], f"{tag}={os.environ[tag]}"
