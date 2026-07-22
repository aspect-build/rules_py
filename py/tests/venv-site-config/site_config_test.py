import os
import site
import sys

print("sys.prefix:", sys.prefix)
print("sys.executable:", sys.executable)
print("site.PREFIXES:", site.PREFIXES)
print("site.getsitepackages():", site.getsitepackages())
print("site.ENABLE_USER_SITE:", site.ENABLE_USER_SITE)

# The virtualenv module must have loaded at interpreter startup.
assert "_virtualenv" in sys.modules

# System-site controls the number of site-packages roots: the venv's own (1)
# vs. the venv plus the base interpreter's (>=2).
expect_system = os.environ.get("EXPECT_SYSTEM_SITE")
if expect_system == "venv_only":
    assert len(site.getsitepackages()) == 1, site.getsitepackages()
elif expect_system == "with_base":
    assert len(site.getsitepackages()) >= 2, site.getsitepackages()

# User-site controls site.ENABLE_USER_SITE, observable only when the launcher
# is not isolated (`-I` forces user-site off regardless of the pyvenv.cfg key).
expect_user = os.environ.get("EXPECT_USER_SITE")
if expect_user == "enabled":
    assert site.ENABLE_USER_SITE is True, site.ENABLE_USER_SITE
elif expect_user == "disabled":
    assert site.ENABLE_USER_SITE is False, site.ENABLE_USER_SITE
