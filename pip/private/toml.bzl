"""Very simplistic parser for PDM lockfiles.

Does not handle general TOML syntax. Use with caution. Should probably be rewritten if we productionize this.
"""

# buildifier: disable=function-docstring
def parse_pdm_lockfile(source):
    # simple state machine
    state = "init"
    # accumulators
    packages, json_lines, dependencies, files = [], [], [], []
    # process lines, converting TOML to JSON in a simple way
    for line in source.split("\n"):
        line = line.strip()
        if line == "[[package]]":
            if state == "package":
                json_lines.append("\"files\": [\n%s\n]" % ",\n".join(files))
                json_lines.append("\"dependencies\": [\n%s\n]" % ",\n".join(dependencies))
                packages.append("{\n%s\n}" % ",\n".join(json_lines))
            state = "package"
            # reset accumulators
            json_lines, files, dependencies = [], [], []
        elif state == "package" and line.find(" = \"") > 0 and line.split(" = ")[0].isalpha():
            # name = "thing" -> "name": "thing"
            key, value = line.split(" = ")
            json_lines.append("\"{}\": {}".format(key, value))
        elif state == "package" and line == "dependencies = [":
            state = "dependencies"
        elif state == "package" and line == "files = [":
            state = "files"
        elif line == "]" and state in ["dependencies", "files"]:
            state = "package"
        elif state == "files":
            files.append(line.replace("url", "\"url\"").replace("hash", "\"hash\"").replace(" = ", ": ").strip(","))
        elif state == "dependencies":
            dependencies.append(line.strip(","))
        else:
            # print("state %s not handling line %s" % (state, line))
            pass
    final_json = "[\n%s\n]" % ",\n".join(packages)
    # print(final_json)
    return json.decode(final_json)
