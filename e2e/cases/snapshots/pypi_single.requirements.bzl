
load("@rules_py//uv/private:normalize_name.bzl", "normalize_name")

all_requirements = ["@@rules_py++uv+pypi_single//cowsay:pkg", "@@rules_py++uv+pypi_single//single_project_hub:pkg"]

all_whl_requirements_by_package = {"cowsay": "@@rules_py++uv+pypi_single//cowsay:whl", "single_project_hub": "@@rules_py++uv+pypi_single//single_project_hub:whl"}

all_whl_requirements = all_whl_requirements_by_package.values()

all_data_requirements = all_requirements

def requirement(name):
    return "@@rules_py++uv+pypi_single//{0}:pkg".format(normalize_name(name))
