import example_ext

assert example_ext.add(2, 3) == 5, example_ext.add(2, 3)
assert example_ext.greet("World") == "Hello, World!", example_ext.greet("World")

print("nanobind extension imported and called successfully")
