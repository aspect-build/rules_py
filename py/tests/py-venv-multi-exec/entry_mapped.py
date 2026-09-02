"""Data targets' runfiles symlink mappings survive the launcher's merge."""

assert "entry_a" in open("mapped.py").read()
assert "entry_a" in open("../root-mapped.py").read()
print("runfiles mappings ok")
