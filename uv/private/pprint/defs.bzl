def pprint(val, indent = "    "):
    # Each entry: [object, indent_level, state, optional_data]
    # States:
    # 0: Dispatch (determine if leaf or container)
    # 1: Container Closer (print ] or } or ))
    # 2: List Item (indent_count + process value + comma)
    # 3: Dict Item (indent_count + key + process value + comma)
    # 4: Struct Item (indent_count + key + = + process value + comma)
    # 5: Post-Value (just prints the comma and newline)

    worklist = [[val, 0, 0]]
    output = []

    # Use a large range to simulate a while loop
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
                    worklist.append([obj, indent_count, 1])  # Add closer
                    for i in range(len(obj) - 1, -1, -1):
                        worklist.append([obj[i], indent_count + 1, 2])
            elif t == "dict":
                if not obj:
                    output.append("{}")
                else:
                    output.append("{\n")
                    worklist.append([obj, indent_count, 1])  # Add closer
                    keys = obj.keys()
                    for i in range(len(keys) - 1, -1, -1):
                        worklist.append([obj[keys[i]], indent_count + 1, 3, keys[i]])
            elif t == "struct":
                output.append("struct(\n")
                worklist.append([obj, indent_count, 1])  # Add closer
                keys = dir(obj)
                for i in range(len(keys) - 1, -1, -1):
                    k = keys[i]
                    worklist.append([getattr(obj, k), indent_count + 1, 4, k])
            else:
                output.append(repr(obj))

        elif state == 1:  # Closer
            t = type(obj)
            char = "]" if t == "list" else "}" if t == "dict" else ")"
            output.append(indent * indent_count + char)

        elif state == 2:  # List Item
            output.append(indent * indent_count)

            # Add the comma to happen AFTER the value is processed
            worklist.append([None, 0, 5])

            # Process the value
            worklist.append([obj, indent_count, 0])

        elif state == 3:  # Dict Item
            key = curr[3]
            output.append(indent * indent_count + repr(key) + ": ")
            worklist.append([None, 0, 5])
            worklist.append([obj, indent_count, 0])

        elif state == 4:  # Struct Item
            key = curr[3]
            output.append(indent * indent_count + key + " = ")
            worklist.append([None, 0, 5])
            worklist.append([obj, indent_count, 0])

        elif state == 5:  # Comma + Newline
            output.append(",\n")

    return "".join(output)
