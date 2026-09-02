"""A .py carried as a library's `data` ships as a plain runtime file."""

content = open("py/tests/py-venv-multi-exec/runtime_data.py").read()
assert "runtime data" in content, content
print("runtime-data fixture ok")
