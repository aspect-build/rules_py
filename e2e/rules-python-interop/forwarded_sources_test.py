"""Both forwarders expose leaf.py; it must import whatever rules_python's
precompilation did to the wrapped library's sources."""

import mid

assert mid.MID == "leaf+mid"
print("OK")
