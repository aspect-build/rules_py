import sys
import site

from colorama import Fore, Style

from branding import get_branding
from adder.add import add

if __name__ == "__main__":
    print(sys.executable)
    print(sys.prefix)
    print(sys.version)
    print(f"{Fore.GREEN}Hello {get_branding()} - {add(3, .14)}{Style.RESET_ALL}")
