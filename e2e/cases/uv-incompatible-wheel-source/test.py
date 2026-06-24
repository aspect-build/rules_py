from aenum import Enum


class Color(Enum):
    RED = 1


assert Color.RED.value == 1
