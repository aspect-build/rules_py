import importlib
import sys


def main():
    print("sys.path entries:")
    for p in sys.path:
        print(p)
    errors = []
    mod_names = sys.argv[1:]
    mods = {}
    for name in mod_names:
        try:
            mods[name] = importlib.import_module(name)
        except ImportError as e:
            errors.append(e)

    assert not errors, f"import errors: {[str(e) for e in errors]}"

    for name in mod_names:
        expected = name
        actual = mods[name].name
        print(f"{name}.name = ", mods[name].name)
        assert expected == actual, f"expected: {expected!r}, actual: {actual!r}"


if __name__ == "__main__":
    main()
