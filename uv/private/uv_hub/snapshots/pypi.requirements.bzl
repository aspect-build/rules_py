
load("@rules_python//python:pip.bzl", "pip_utils")

# We arne't compatible with this because it isn't constant over venvs.
# all_requirements = []

# We aren't compatible with this because it isn't constant over venvs.
# all_whl_requirements_by_package = {}

# We aren't compatible with this because it isn't constant over venvs.
# all_whl_requirements = all_whl_requirements_by_package.values()

# We aren't compatible with this because we don't offer separate data targets
# all_data_requirements = []

def requirement(name):
    return "@@+uv+pypi//{0}:{0}".format(pip_utils.normalize_name(name))
