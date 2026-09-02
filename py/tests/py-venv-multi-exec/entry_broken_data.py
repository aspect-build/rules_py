"""A syntactically invalid .py used strictly as data is never parsed."""

content = open("py/tests/py-venv-multi-exec/broken_data.py").read()
assert "deliberately not valid" in content, content
print("broken data ok")
