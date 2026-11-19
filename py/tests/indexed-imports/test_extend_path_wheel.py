"""A first-party pkgutil package extends its path into a wheel's namespace."""

import splitgraft.first_party
import splitgraft.wheel_part

assert splitgraft.first_party.VALUE == "first-party"
assert splitgraft.wheel_part.VALUE == "wheel"
