import tree_module

assert tree_module.VALUE == 42
assert tree_module.__file__.endswith(".py"), tree_module.__file__
