"""A venv src listed from another package ships at that package's path."""

content = open("py/tests/py-venv-multi-exec/cross-pkg/foreign_source.py").read()
assert 'VALUE = "foreign direct source"' in content, content
print("foreign source ok")
