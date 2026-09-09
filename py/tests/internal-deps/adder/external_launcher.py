import os

from adder.add import add


def rlocation(apparent_repo, path):
    runfiles_dir = os.environ["RUNFILES_DIR"]
    with open(os.path.join(runfiles_dir, "_repo_mapping")) as mapping:
        for line in mapping:
            _, apparent, canonical = line.rstrip("\n").split(",")
            if apparent == apparent_repo:
                return os.path.join(runfiles_dir, canonical, path)
    return None


if __name__ == "__main__":
    adder_path = rlocation("aspect_rules_py", "py/tests/internal-deps/adder/add.py")
    if adder_path is None or not os.path.exists(adder_path):
        raise RuntimeError("could not resolve adder through runfiles")
    print("external {}".format(add(2, 3)))
