from importlib.metadata import version

# Regression test for PEP 440 versions with characters invalid in Bazel repo
# names. normalize_version must sanitize any character outside [A-Za-z0-9_-]
# to '_', otherwise the generated repo name is malformed and the build fails.
#
#   jaxlib "0.4.25+cuda11.cudnn86" exercises '+' (local-version segment).
#   metomi-isodatetime "1!3.1.0"   exercises '!' (PEP 440 epoch).
jaxlib_version = version("jaxlib")
assert jaxlib_version == "0.4.25+cuda11.cudnn86", "version is " + jaxlib_version

isodatetime_version = version("metomi-isodatetime")
assert isodatetime_version == "1!3.1.0", "version is " + isodatetime_version

print("odd-version regression test passed!")
