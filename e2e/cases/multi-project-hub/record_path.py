"""Print the resolved on-disk location of `cowsay.__file__` for the current
build configuration. Used by `:hub_dep_single_compile_test` to compare what
multiple `dep_group` consumers see for the same hub package."""

from pathlib import Path

import cowsay

print(Path(cowsay.__file__).resolve())
