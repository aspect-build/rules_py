#!/usr/bin/env python3
from pydantic_core import core_schema, SchemaValidator


def main() -> None:
    validator = SchemaValidator(core_schema.int_schema())
    result = validator.validate_python("123")
    # pydantic-core's lax int mode coerces the numeric string to a real int.
    assert result == 123 and isinstance(result, int), "expected int 123, got {!r}".format(result)
    print("OK")


if __name__ == "__main__":
    main()
