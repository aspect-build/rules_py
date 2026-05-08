import shared_lib
import cowsay

# This script is the consumer's `main =` but is NOT listed in
# `:shared_venv.srcs`. Both imports below resolve through the venv —
# `shared_lib` from the venv's sys.path, `cowsay` from its wheel deps —
# proving that `main` and the venv's source closure are independent.
assert shared_lib.GREETING == "hello from the shared venv"
assert hasattr(cowsay, "get_output_string")

print("entry_outside_srcs ok")
