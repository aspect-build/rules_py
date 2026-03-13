"""A tiny Flask app used to demonstrate dev-dependency toggling."""

import os

from flask import Flask

app = Flask(__name__)


@app.route("/")
def hello():
    return "Hello from the dev_deps example!"


def main():
    debug = os.environ.get("FLASK_DEBUG", "0") == "1"

    if debug:
        # ipdb is only available when built in dev mode (the default).
        # In release mode (--config=release) this import would fail.
        try:
            import ipdb  # noqa: F401

            print("ipdb is available — breakpoints will use ipdb")
        except ImportError:
            print("ipdb is NOT available — using default debugger")

    app.run(debug=debug, port=5000)


if __name__ == "__main__":
    main()
