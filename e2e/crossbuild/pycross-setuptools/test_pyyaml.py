# Ported from rules_pycross tests/e2e/build_setuptools/tests/test_pyyaml.py.
# The `CLoader` assertion is added: rules_pycross's version tolerates either
# backend, which leaves its `build_env` override untested. The build sets
# PYYAML_FORCE_LIBYAML=0, so the source build must have produced the pure-Python
# backend — if the override never reached the build action, CLoader is present.
import yaml


def test_pyyaml_import():
    try:
        from yaml import CLoader as Loader
    except ImportError:
        from yaml import Loader
    else:
        raise AssertionError("PYYAML_FORCE_LIBYAML=0 did not reach the build: CLoader exists")

    data = yaml.load("hello: world\nlist:\n  - 1\n  - 2\n", Loader=Loader)
    assert data == {"hello": "world", "list": [1, 2]}
    print("PyYAML loaded successfully!")


if __name__ == "__main__":
    test_pyyaml_import()
