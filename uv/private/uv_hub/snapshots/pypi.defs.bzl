
VIRTUALENVS = [
    "aspect_rules_py",
]
_repo = "+uv+pypi"

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
