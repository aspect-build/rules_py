"""Import a wheel whose `.dist-info` case differs from its filename (#1394).

The wheel is `InquirerPy-0.3.4-py3-none-any.whl` but its metadata lives in
`inquirerpy-0.3.4.dist-info`, so the layout must come from the archive rather
than from the filename's project name.
"""

from InquirerPy import inquirer


def main() -> None:
    assert inquirer.text is not None


if __name__ == "__main__":
    main()
