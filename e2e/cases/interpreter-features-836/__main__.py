import importlib.util
import sys

if __name__ == "__main__":
    turtle_spec = importlib.util.find_spec("turtle")
    turtledemo_spec = importlib.util.find_spec("turtledemo")

    if turtle_spec is not None:
        print(f"FAIL: turtle found at {turtle_spec.origin}")
        sys.exit(1)

    if turtledemo_spec is not None:
        print(f"FAIL: turtledemo found at {turtledemo_spec.origin}")
        sys.exit(1)

    print("OK: turtle and turtledemo are not importable")
