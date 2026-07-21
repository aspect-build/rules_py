import cowsay
import six

assert "git build dependency" in cowsay.get_output_string("cow", "git build dependency")
assert six.__version__ == "1.17.0", six.__version__
assert six.ensure_str(b"git-source") == "git-source"

print("six", six.__version__, "and cowsay imported from source builds")
