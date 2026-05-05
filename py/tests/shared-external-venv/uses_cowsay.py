"""A trivial binary-side entrypoint that imports cowsay from the shared venv.

Success is measured by "import works, version attribute is accessible";
if the shared venv isn't wiring cowsay onto sys.path for this binary's
launcher, the import blows up.
"""

import cowsay


def main():
    msg = cowsay.get_output_string("cow", "hello from shared venv")
    assert "hello from shared venv" in msg, msg
    print(msg)


if __name__ == "__main__":
    main()
