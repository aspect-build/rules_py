import runfiles

r = runfiles.Create()
# source_repo skips CurrentRepository's caller-frame inspection, which
# cannot see through the venv's site-packages indirection.
payload = open(r.Rlocation("_main/py/tests/py-pex-binary/links_link/payload.txt", source_repo="")).read()
nested = open(r.Rlocation("_main/py/tests/py-pex-binary/links_link/sub/nested.txt", source_repo="")).read()

assert payload == "dir-symlink-payload", payload
assert nested == "nested-payload", nested

print(payload + "," + nested)
