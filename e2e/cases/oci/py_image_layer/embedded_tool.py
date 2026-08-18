"""Embedded tool fixture; the imports prove the dep closure ships."""

import colorama  # noqa: F401
import embedded_support  # noqa: F401

if __name__ == "__main__":
    print("embedded tool")
