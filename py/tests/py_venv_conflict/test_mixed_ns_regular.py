"""Verify that a namespace package (no __init__.py) and a regular package
(has __init__.py at the top-level) claiming the same top-level are both
accessible after a physical merge.

Scenario: xds_protos-like wheel ships `opentelemetry/__init__.py` (regular)
while opentelemetry-sdk-like wheel ships `opentelemetry/sdk/` (namespace).
Without the fix, the regular wheel's `opentelemetry/` directory would win the
symlink and hide the namespace wheel's content.
"""

# From the namespace wheel (no __init__.py at opentelemetry/)
from mixed_top.from_namespace import VALUE as NS_VALUE

# From the regular wheel (has opentelemetry/__init__.py)
from mixed_top.from_regular import VALUE as REG_VALUE

assert NS_VALUE == "namespace", NS_VALUE
assert REG_VALUE == "regular", REG_VALUE
