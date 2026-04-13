from pathlib import Path
import subprocess

def main() -> None:
    binary = Path(__file__).with_name("binary")
    result = subprocess.run([str(binary)], check = True, capture_output = True, text = True)
    assert result.stdout.strip() == "reset ok", result.stdout


if __name__ == "__main__":
    main()
