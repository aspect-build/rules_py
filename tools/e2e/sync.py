#!/usr/bin/env python3

import re
from os import getenv
from pathlib import Path

WORKSPACES_BLOCK_RE = re.compile(r"""\
# SYNC: e2e
# {{{
(.*?
)# }}}
""", re.MULTILINE | re.DOTALL)

if __name__ == "__main__" or 1:
    root = Path(__file__).parent.parent.parent.absolute()
    workflows_file = root / ".aspect/workflows/config.yaml"
    modules = root.rglob("**/MODULE.bazel")
    module_roots = [it.parent.relative_to(root) for it in modules]

    # Module roots that we know we can't run in workflows
    ignored_roots = [
        Path("e2e/use_release"),
        Path("e2e/cross-repo-610/subrepo_a"),
        Path("e2e/cross-repo-610/subrepo_b"),
    ]

    module_roots = [
        r for r in module_roots if r not in ignored_roots
    ]
    module_roots = sorted(module_roots)
    
   
    with open(workflows_file, "r") as fp:
        config = fp.read()

    def _handler(m):
        return m.group(0).replace(m.group(1), "".join(["  - {}\n".format(it) for it in module_roots]))

    new_config = re.sub(WORKSPACES_BLOCK_RE, _handler, config)

    if config != new_config:
        print(new_config)

        with open(workflows_file, "w") as fp:
            fp.write(new_config)

        exit(1)
