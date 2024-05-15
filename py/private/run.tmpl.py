import sys
import os
import subprocess

print(sys.argv)

subprocess.run([
  "runfiles/{{VENV_TOOL}}",
  "--location", "runfiles/{{ARG_VENV_NAME}}",
  "--python-version", "{{ARG_VENV_PYTHON_VERSION}}",
  "--pth-file", "{{ARG_PTH_FILE}})"
])

env = {{PYTHON_ENV}}
env["PATH"] = "/runfiles/{{ARG_VENV_NAME}}/bin:%s" % os.environ("PATH")

subprocess.run([
  "{{EXEC_PYTHON_BIN}}",
  {{INTERPRETER_FLAGS}},
  "{{ENTRYPOINT}}",
  # "$@"
], env = env)
