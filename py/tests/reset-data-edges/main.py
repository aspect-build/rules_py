from pathlib import Path

EXPECTED = """python_version=3.11
rules_python_version=3.11
dep_group=
freethreaded=False
"""


def assert_probe(name: str) -> None:
    actual = Path(__file__).with_name(name).read_text()
    assert actual == EXPECTED, "{} had unexpected contents: {!r}".format(name, actual)


def main() -> None:
    assert_probe("binary_probe.txt")
    assert_probe("library_probe.txt")
    print("reset ok")


if __name__ == "__main__":
    main()
