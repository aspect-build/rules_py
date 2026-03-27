import cowsay

# Verify the package can be used - regression test for versions containing '+'
# Previously, a version like "6.1+local" would produce an invalid Bazel repo
# name "whl_install__...__6_1+local" because '+' is not allowed in repo names.
cowsay.cow("hello from +version regression test")
