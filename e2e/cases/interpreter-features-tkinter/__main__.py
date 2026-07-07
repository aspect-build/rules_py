import importlib.util
import sys

from verify_venv import verify_all

if __name__ == "__main__":
    verify_all()

    tkinter_spec = importlib.util.find_spec("tkinter")
    if tkinter_spec is not None:
        print(f"FAIL: tkinter found at {tkinter_spec.origin}")
        sys.exit(1)

    try:
        import _tkinter  # noqa: F401
        print("FAIL: _tkinter is importable")
        sys.exit(1)
    except ImportError:
        pass

    print("OK: tkinter and _tkinter are not importable")
