"""A tiny Flask app used to demonstrate debugpy integration."""

from flask import Flask

app = Flask(__name__)


@app.route("/")
def hello():
    return "Hello from the debugger example!"


def main():
    app.run(debug=False, port=5000)


if __name__ == "__main__":
    main()
