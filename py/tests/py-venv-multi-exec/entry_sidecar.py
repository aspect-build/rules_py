import os

here = os.path.dirname(__file__)
content = open(os.path.join(here, "sidecar.txt")).read()
assert content == "sidecar-content\n", repr(content)
print("sidecar ok")
