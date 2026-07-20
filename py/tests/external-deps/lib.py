from colorama import Fore, Style

def greet(name: str) -> str:
    return f"{Fore.GREEN}Hello {name}{Style.RESET_ALL}"
