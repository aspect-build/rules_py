import os
import tempfile
from pathlib import Path

from symlinks import main


with tempfile.TemporaryDirectory() as temporary_directory:
    root = Path(temporary_directory)
    first = root / "site-packages/example"
    nested = root / "site-packages/namespace/example"
    params = root / "symlinks.params"
    params.write_text("\n".join([
        str(first),
        "../../../wheel/site-packages/example",
        str(nested),
        "../../../../wheel/site-packages/namespace/example",
    ]))

    main(params)

    assert os.readlink(first) == "../../../wheel/site-packages/example"
    assert os.readlink(nested) == "../../../../wheel/site-packages/namespace/example"
