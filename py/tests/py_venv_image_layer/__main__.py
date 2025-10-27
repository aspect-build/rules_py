import sys
import site

import colorama
from colorama import Fore, Style

import branding
from branding import get_branding

from adder.add import add

if __name__ == "__main__":
    print(sys.executable)
    print(sys.prefix)
    print(sys.version)
    print(colorama.__file__)
    print(branding.__file__)
    print(f"{Fore.GREEN}Hello {get_branding()} - {add(3, .14)}{Style.RESET_ALL}")
