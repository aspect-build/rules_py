import cowsay
import six

# strings on one line to test presence for all
print("/".join(cowsay.__file__.split("/")[-3:])
      + ","
      + "/".join(six.__file__.split("/")[-2:]))
