import cowsay
import sys

print(cowsay.get_output_string("cow", 'hello py_binary, %s!' % sys.version))
