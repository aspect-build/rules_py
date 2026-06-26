#!/usr/bin/env python3

from importlib import metadata

import markupsafe

assert metadata.version("markupsafe") == "3.0.3"
assert str(markupsafe.escape("<x>")) == "&lt;x&gt;"
