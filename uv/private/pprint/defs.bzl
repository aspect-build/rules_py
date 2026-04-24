"""Pretty-printing utilities for Starlark data structures.

This module provides a recursive-descent pretty-printer implemented
iteratively (Starlark does not guarantee recursion support in all
Bazel evaluation contexts).  It formats `list`, `dict` and `struct`
values with indentation and trailing commas.
"""

def pprint(val, indent = "    "):
    """Return a human-readable, indented representation of a Starlark value.

    Supported types:
      * `list`   – formatted as `[...]` with one item per line.
      * `dict`   – formatted as `{...}` with one key/value pair per line.
      * `struct` – formatted as `struct(...)` with one field per line.
      * all other values are rendered via `repr()`.

    The algorithm uses an explicit work-list (stack) and a small state
    machine so that no recursive calls are required.

    Work-list entries have the shape:
      `[object, indent_level, state, optional_data]`

    States:
      * `0` – Dispatch: decide whether the object is a leaf or a container.
      * `1` – Container closer: emit the closing `]`, `}` or `)`.
      * `2` – List item: emit indentation, the value and a trailing comma.
      * `3` – Dict item: emit `key: `, the value and a trailing comma.
      * `4` – Struct item: emit `key = `, the value and a trailing comma.
      * `5` – Post-value: emit `,\n`.

    Args:
      val:    the value to pretty-print.
      indent: string used for one level of indentation (default four spaces).

    Returns:
      A formatted string representation of `val`.
    """
    worklist = [[val, 0, 0]]
    output = []

    for _ in range(100000):
        if not worklist:
            break

        curr = worklist.pop()
        obj, indent_count, state = curr[0], curr[1], curr[2]

        if state == 0:
            t = type(obj)
            if t == "list":
                if not obj:
                    output.append("[]")
                else:
                    output.append("[\n")
                    worklist.append([obj, indent_count, 1])
                    for i in range(len(obj) - 1, -1, -1):
                        worklist.append([obj[i], indent_count + 1, 2])
            elif t == "dict":
                if not obj:
                    output.append("{}")
                else:
                    output.append("{\n")
                    worklist.append([obj, indent_count, 1])
                    keys = obj.keys()
                    for i in range(len(keys) - 1, -1, -1):
                        worklist.append([obj[keys[i]], indent_count + 1, 3, keys[i]])
            elif t == "struct":
                output.append("struct(\n")
                worklist.append([obj, indent_count, 1])
                keys = dir(obj)
                for i in range(len(keys) - 1, -1, -1):
                    k = keys[i]
                    worklist.append([getattr(obj, k), indent_count + 1, 4, k])
            else:
                output.append(repr(obj))

        elif state == 1:
            t = type(obj)
            char = "]" if t == "list" else "}" if t == "dict" else ")"
            output.append(indent * indent_count + char)

        elif state == 2:
            output.append(indent * indent_count)
            worklist.append([None, 0, 5])
            worklist.append([obj, indent_count, 0])

        elif state == 3:
            key = curr[3]
            output.append(indent * indent_count + repr(key) + ": ")
            worklist.append([None, 0, 5])
            worklist.append([obj, indent_count, 0])

        elif state == 4:
            key = curr[3]
            output.append(indent * indent_count + key + " = ")
            worklist.append([None, 0, 5])
            worklist.append([obj, indent_count, 0])

        elif state == 5:
            output.append(",\n")

    return "".join(output)
