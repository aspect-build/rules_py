from colorama import Fore, Style

from branding import get_branding
from adder.add import add

if __name__ == "__main__":
    print(f"{Fore.GREEN}Hello {get_branding()} - {add(3, .14)}{Style.RESET_ALL}")
