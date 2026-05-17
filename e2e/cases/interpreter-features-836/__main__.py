import importlib.util
import sys

from verify_venv import verify_all

if __name__ == "__main__":
    verify_all()

    turtle_spec = importlib.util.find_spec("turtle")
    turtledemo_spec = importlib.util.find_spec("turtledemo")

    if turtle_spec is not None:
        print(f"FAIL: turtle found at {turtle_spec.origin}")
        sys.exit(1)

    if turtledemo_spec is not None:
        print(f"FAIL: turtledemo found at {turtledemo_spec.origin}")
        sys.exit(1)

    print("OK: turtle and turtledemo are not importable")
