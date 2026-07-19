import importlib


def _assert_absent(module: str) -> None:
    try:
        importlib.import_module(module)
    except ImportError:
        return
    raise AssertionError(
        "{} imported on a non-Windows host; an inactive marker-only dependency "
        "should resolve to the empty package and contribute nothing".format(module)
    )


def _assert_present(module: str) -> None:
    importlib.import_module(module)


def main() -> None:
    _assert_absent("iniconfig")
    _assert_absent("six")
    _assert_present("tqdm")
    _assert_absent("colorama")


if __name__ == "__main__":
    main()
