VIRTUALENVS = [
    "aspect_rules_py",
]

def compatible_with(venvs, extra_constraints = []):
    for v in venvs:
        if v not in VIRTUALENVS:
            fail("Errant virtualenv reference %r" % v)

    return {
        Label("//dep_group:" + it): extra_constraints
        for it in venvs
    } | {
        "//conditions:default": ["@platforms//:incompatible"],
    }

def incompatible_with(venvs, extra_constraints = []):
    for v in venvs:
        if v not in VIRTUALENVS:
            fail("Errant virtualenv reference %r" % v)

    return {
        Label("//dep_group:" + it): ["@platforms//:incompatible"]
        for it in venvs
    } | {
        "//conditions:default": extra_constraints,
    }

_DEPS_BY_GROUP = {
    "aspect_rules_py": [
        "@@+uv+pypi//arrow:pkg",
        "@@+uv+pypi//asgiref:pkg",
        "@@+uv+pypi//aspect_rules_py:pkg",
        "@@+uv+pypi//attrs:pkg",
        "@@+uv+pypi//bazel_runfiles:pkg",
        "@@+uv+pypi//boto3:pkg",
        "@@+uv+pypi//botocore:pkg",
        "@@+uv+pypi//bravado:pkg",
        "@@+uv+pypi//bravado_core:pkg",
        "@@+uv+pypi//build:pkg",
        "@@+uv+pypi//certifi:pkg",
        "@@+uv+pypi//charset_normalizer:pkg",
        "@@+uv+pypi//click:pkg",
        "@@+uv+pypi//colorama:pkg",
        "@@+uv+pypi//coverage:pkg",
        "@@+uv+pypi//cowsay:pkg",
        "@@+uv+pypi//django:pkg",
        "@@+uv+pypi//exceptiongroup:pkg",
        "@@+uv+pypi//fqdn:pkg",
        "@@+uv+pypi//ftfy:pkg",
        "@@+uv+pypi//future:pkg",
        "@@+uv+pypi//gitdb:pkg",
        "@@+uv+pypi//gitpython:pkg",
        "@@+uv+pypi//idna:pkg",
        "@@+uv+pypi//importlib_metadata:pkg",
        "@@+uv+pypi//iniconfig:pkg",
        "@@+uv+pypi//isoduration:pkg",
        "@@+uv+pypi//jmespath:pkg",
        "@@+uv+pypi//jsonpointer:pkg",
        "@@+uv+pypi//jsonref:pkg",
        "@@+uv+pypi//jsonschema:pkg",
        "@@+uv+pypi//jsonschema_specifications:pkg",
        "@@+uv+pypi//maturin:pkg",
        "@@+uv+pypi//monotonic:pkg",
        "@@+uv+pypi//msgpack:pkg",
        "@@+uv+pypi//neptune:pkg",
        "@@+uv+pypi//numpy:pkg",
        "@@+uv+pypi//oauthlib:pkg",
        "@@+uv+pypi//packaging:pkg",
        "@@+uv+pypi//pandas:pkg",
        "@@+uv+pypi//pillow:pkg",
        "@@+uv+pypi//pkg:pkg",
        "@@+uv+pypi//pluggy:pkg",
        "@@+uv+pypi//psutil:pkg",
        "@@+uv+pypi//pyjwt:pkg",
        "@@+uv+pypi//pyproject_hooks:pkg",
        "@@+uv+pypi//pytest:pkg",
        "@@+uv+pypi//python_dateutil:pkg",
        "@@+uv+pypi//pytz:pkg",
        "@@+uv+pypi//pyyaml:pkg",
        "@@+uv+pypi//referencing:pkg",
        "@@+uv+pypi//requests:pkg",
        "@@+uv+pypi//requests_oauthlib:pkg",
        "@@+uv+pypi//rfc3339_validator:pkg",
        "@@+uv+pypi//rfc3986_validator:pkg",
        "@@+uv+pypi//rpds_py:pkg",
        "@@+uv+pypi//s3transfer:pkg",
        "@@+uv+pypi//setuptools:pkg",
        "@@+uv+pypi//simplejson:pkg",
        "@@+uv+pypi//six:pkg",
        "@@+uv+pypi//smmap:pkg",
        "@@+uv+pypi//snakesay:pkg",
        "@@+uv+pypi//sqlparse:pkg",
        "@@+uv+pypi//swagger_spec_validator:pkg",
        "@@+uv+pypi//tomli:pkg",
        "@@+uv+pypi//types_python_dateutil:pkg",
        "@@+uv+pypi//typing_extensions:pkg",
        "@@+uv+pypi//tzdata:pkg",
        "@@+uv+pypi//uri_template:pkg",
        "@@+uv+pypi//urllib3:pkg",
        "@@+uv+pypi//wcwidth:pkg",
        "@@+uv+pypi//webcolors:pkg",
        "@@+uv+pypi//websocket_client:pkg",
        "@@+uv+pypi//zipp:pkg",
    ],
}

_GROUP_DEPS = select(
    {
        Label("//dep_group:" + group): deps
        for group, deps in _DEPS_BY_GROUP.items()
    },
    no_match_error = "no dep_group selected; set the dep_group attribute on the consuming target to one of: aspect_rules_py",
)

def group_dep_labels(group):
    if group not in _DEPS_BY_GROUP:
        fail("unknown dep_group %r; expected one of: %s" % (group, ", ".join(sorted(_DEPS_BY_GROUP))))
    return [Label(dep) for dep in _DEPS_BY_GROUP[group]]

def group_deps():
    return _GROUP_DEPS
