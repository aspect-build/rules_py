from pkg import generated

assert generated.VALUE == 1
assert generated.__file__.endswith(".pyc"), generated.__file__
