import shared_lib
import cowsay

# This consumer lives in a different package than `:shared_venv`.
# Imports still resolve through the venv's sys.path / wheel deps —
# the launcher's exec'd python uses the venv's interpreter regardless
# of where the launcher rule lives.
assert shared_lib.GREETING == "hello from the shared venv"
assert hasattr(cowsay, "get_output_string")

print("entry_cross_pkg ok")
