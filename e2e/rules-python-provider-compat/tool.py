"""An already-migrated binary: built by rules_py, depended on by an @rules_python test."""

from lib import GREETING

TOOL_NAME = "rules_py tool"

if __name__ == "__main__":
    print(GREETING)
