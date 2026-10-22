"""Both forwarders expose leaf.py; under bytecode modes it must come from one
action. Its pyc_config_test wrappers set EXPECT_PYC alongside the flag."""

import os

import leaf
import mid

if os.environ.get("EXPECT_PYC") == "sourceless":
    for module in (leaf, mid):
        path = module.__file__
        sourceless = path if path.endswith(".pyc") else path[: -len(".py")] + ".pyc"
        assert os.path.exists(sourceless), os.listdir(os.path.dirname(path))

assert mid.MID == "leaf+mid"
print("OK")
