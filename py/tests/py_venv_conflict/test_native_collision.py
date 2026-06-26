from importlib.util import find_spec

from collision_order import second


assert second.VALUE == "second", second.VALUE
assert find_spec("collision_order.first") is None
assert second.sibling_value() == "second"
