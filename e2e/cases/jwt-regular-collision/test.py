"""Regression for two regular wheels contributing to one package directory."""

from pathlib import Path
import sysconfig

import jwt.api_jwt


site_packages = Path(sysconfig.get_paths()["purelib"])
jwt_dir = site_packages / "jwt"

assert (jwt_dir / "api_jwt.py").is_file(), jwt_dir
assert (jwt_dir / "jwa.py").is_file(), jwt_dir
assert Path(jwt.api_jwt.__file__).parent.samefile(jwt_dir)
