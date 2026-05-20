import cowsay

# Confirms the dep (loaded via :pkg / requirement() / all_requirements) brought
# cowsay onto sys.path.
assert hasattr(cowsay, "cow"), "cowsay.cow should be importable"
print("cowsay importable via the rules_python-compat surface")
