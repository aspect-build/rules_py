
load("@rules_python//python:pip.bzl", "pip_utils")

all_requirements = ["@@aspect_rules_py++uv+pypi_single//cowsay:pkg", "@@aspect_rules_py++uv+pypi_single//single_project_hub:pkg"]

all_whl_requirements_by_package = {"cowsay": "@@aspect_rules_py++uv+pypi_single//cowsay:whl", "single_project_hub": "@@aspect_rules_py++uv+pypi_single//single_project_hub:whl"}

all_whl_requirements = all_whl_requirements_by_package.values()

all_data_requirements = all_requirements

def requirement(name):
    return "@@aspect_rules_py++uv+pypi_single//{0}:pkg".format(pip_utils.normalize_name(name))
