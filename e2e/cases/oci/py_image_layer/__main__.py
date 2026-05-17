from colorama import Fore, Style

from branding import get_branding
from adder.add import add
from verify_venv import verify_all

if __name__ == "__main__":
    verify_all(imports=["colorama"])
    print(f"{Fore.GREEN}Hello {get_branding()} - {add(3, .14)}{Style.RESET_ALL}")
