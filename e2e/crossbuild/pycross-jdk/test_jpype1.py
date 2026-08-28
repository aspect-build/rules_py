#!/usr/bin/env python3
import jpype


def main() -> None:
    # jpype.__version__ is a plain constant baked into the pure-Python
    # package — checking it proves the compiled _jpype extension (and its
    # Java-side JAR, built via Ant) imported successfully, without needing
    # to actually start a JVM at runtime (which would need a target-arch JRE).
    assert jpype.__version__ == "1.7.1", "expected jpype 1.7.1, got {}".format(jpype.__version__)
    print("OK")


if __name__ == "__main__":
    main()
