import cowsay
import sys

cowsay.cow('hello py_binary, %s!' % sys.version)  # ty: ignore[unresolved-attribute]
