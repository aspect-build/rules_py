import formatting
import styling
import version


def greet(name: str) -> str:
    return formatting.banner("Hello, {}! (v{})".format(styling.shout(name), version.VERSION))
