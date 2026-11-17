"""A regular package whose namespace subpackages span two import roots."""

import splitreg.b.c.x

assert splitreg.b.c.x.VALUE == "x"
