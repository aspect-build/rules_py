import os

# Non-.py files listed in the venv's `srcs` must ship in every bytecode mode,
# at their natural runfiles path next to the (compiled) module.
here = os.path.dirname(__file__)
content = open(os.path.join(here, "sidecar.txt")).read()
assert content == "sidecar-content\n", repr(content)
print("sidecar ok")
