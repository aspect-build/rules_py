from importlib import metadata

import six

assert metadata.version("six") == "1.16.0"
assert six.PY3
