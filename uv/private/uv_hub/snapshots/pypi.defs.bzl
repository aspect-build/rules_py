
VIRTUALENVS = [
    "aspect_rules_py",
]
_repo = "+uv+pypi"

def compatible_with(venvs, extra_constraints = []):
  for v in venvs:
    if v not in VIRTUALENVS:
      fail("Errant virtualenv reference %r" % v)

  result = {
    Label("//dep_group:" + it): extra_constraints
    for it in venvs
  }

  # When a package is only available in a single virtualenv, allow it to be
  # used without an explicit dep_group selection for convenience.
  if len(venvs) == 1:
    result["//conditions:default"] = extra_constraints
  else:
    result["//conditions:default"] = ["@platforms//:incompatible"]

  return result

def incompatible_with(venvs, extra_constraints = []):
  for v in venvs:
    if v not in VIRTUALENVS:
      fail("Errant virtualenv reference %r" % v)

  result = {
    Label("//dep_group:" + it): ["@platforms//:incompatible"]
    for it in venvs
  }

  if len(venvs) == 1:
    result["//conditions:default"] = extra_constraints
  else:
    result["//conditions:default"] = ["@platforms//:incompatible"]

  return result
