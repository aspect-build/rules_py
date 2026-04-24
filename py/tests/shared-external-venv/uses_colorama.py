"""A second binary-side entrypoint, sharing the venv with uses_cowsay.py.

Imports a DIFFERENT wheel (colorama) to confirm both wheels in the
shared venv are reachable — not just the first one an interpreter
happens to resolve.
"""

import colorama


def main():
    colorama.init(autoreset=True)
    print(f"{colorama.Fore.GREEN}hello from shared venv (colorama path){colorama.Style.RESET_ALL}")
    # Smoke test: the attribute exists and is a string
    assert isinstance(colorama.Fore.GREEN, str)


if __name__ == "__main__":
    main()
