from prefix_namespace.package import shallow
from prefix_namespace.package.deep import value


assert shallow.VALUE == "shallow", shallow.VALUE
assert value.VALUE == "deep", value.VALUE
