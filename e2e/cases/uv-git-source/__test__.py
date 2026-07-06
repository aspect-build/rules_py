import six

assert six.__version__ == "1.17.0", six.__version__
assert six.ensure_str(b"git-source") == "git-source"

print("six", six.__version__, "imported from git source")
