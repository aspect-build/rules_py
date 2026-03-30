from importlib.metadata import version

# Verify the package is installed in the venv - regression test for versions containing '+'
# Previously, a version like "0.4.25+cuda11.cudnn86" would produce an invalid Bazel repo
# name because '+' is not allowed in repo names.
jaxlib_version = version("jaxlib")
assert jaxlib_version == "0.4.25+cuda11.cudnn86", "version is " + jaxlib_version
print("jaxlib (version 0.4.25+cuda11.cudnn86) found - regression test passed!")
