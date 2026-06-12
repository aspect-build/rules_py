"""Regression: rdflib must be importable on Linux.

Reported error:
  @@aspect_rules_py++uv+pypi//rdflib:rdflib (cae838)
    <-- target platform (...:linux_host_platform) didn't satisfy constraint
        @@platforms//:incompatible
"""

import rdflib
from rdflib import Graph

g = Graph()
assert rdflib.__version__ == "7.1.1", rdflib.__version__
print("rdflib", rdflib.__version__, "imported and Graph() constructed successfully")
