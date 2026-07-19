"""Patches that are applied at runtime to the virtual environment."""

from __future__ import annotations

import os
import sys

# Defining this locally avoids importing typing at startup.
TYPE_CHECKING = False
if TYPE_CHECKING:
    from importlib.machinery import ModuleSpec
    from types import ModuleType
    import threading
    from typing import Callable, List, MutableMapping, Optional, Protocol, Sequence, Tuple


    class _Distribution(Protocol):
        def get_option_dict(self, command: str) -> MutableMapping[str, Tuple[str, str]]: ...


# Make wheel-declared console scripts reachable via `subprocess.run("name", ...)`.
# Use dirname(sys.executable) so this works on Windows too, where the scripts
# dir is `Scripts/` rather than `bin/`.
_venv_bin = os.path.dirname(sys.executable)
if _venv_bin not in os.environ.get("PATH", "").split(os.pathsep):
    os.environ["PATH"] = _venv_bin + os.pathsep + os.environ.get("PATH", "")
del _venv_bin

VIRTUALENV_PATCH_FILE = os.path.join(__file__)


def patch_dist(dist: ModuleType) -> None:
    """
    Distutils allows user to configure some arguments via a configuration file:
    https://docs.python.org/3.11/install/index.html#distutils-configuration-files.

    Some of this arguments though don't make sense in context of the virtual environment files, let's fix them up.
    """  # noqa: D205
    # we cannot allow some install config as that would get packages installed outside of the virtual environment
    old_parse_config_files = dist.Distribution.parse_config_files

    def parse_config_files(self: _Distribution, *args: object, **kwargs: object) -> object:
        result = old_parse_config_files(self, *args, **kwargs)
        install = self.get_option_dict("install")

        if "prefix" in install:  # the prefix governs where to install the libraries
            install["prefix"] = VIRTUALENV_PATCH_FILE, os.path.abspath(sys.prefix)
        for base in ("purelib", "platlib", "headers", "scripts", "data"):
            key = f"install_{base}"
            if key in install:  # do not allow global configs to hijack venv paths
                install.pop(key, None)
        return result

    dist.Distribution.parse_config_files = parse_config_files


# Import hook that patches some modules to ignore configuration values that break package installation in case
# of virtual environments.
_DISTUTILS_PATCH = "distutils.dist", "setuptools.dist"
# https://docs.python.org/3/library/importlib.html#setting-up-an-importer


class _Finder:
    """A meta path finder that allows patching the imported distutils modules."""

    fullname: Optional[str] = None

    # lock[0] is threading.Lock(), but initialized lazily to avoid importing threading very early at startup,
    # because there are gevent-based applications that need to be first to import threading by themselves.
    # See https://github.com/pypa/virtualenv/issues/1895 for details.
    lock: "List[threading.Lock]" = []  # noqa: RUF012

    def find_spec(
        self,
        fullname: str,
        path: Optional[Sequence[str]],
        target: Optional[ModuleType] = None,
    ) -> Optional[ModuleSpec]:  # noqa: ARG002
        if fullname in _DISTUTILS_PATCH and self.fullname is None:
            # initialize lock[0] lazily
            if len(self.lock) == 0:
                import threading

                lock = threading.Lock()
                # there is possibility that two threads T1 and T2 are simultaneously running into find_spec,
                # observing .lock as empty, and further going into hereby initialization. However due to the GIL,
                # list.append() operation is atomic and this way only one of the threads will "win" to put the lock
                # - that every thread will use - into .lock[0].
                # https://docs.python.org/3/faq/library.html#what-kinds-of-global-value-mutation-are-thread-safe
                self.lock.append(lock)

            from functools import partial
            from importlib.util import find_spec

            with self.lock[0]:
                self.fullname = fullname
                try:
                    spec = find_spec(fullname)
                    if spec is not None:
                        # https://www.python.org/dev/peps/pep-0451/#how-loading-will-work
                        assert spec.loader is not None
                        old = getattr(spec.loader, "exec_module")
                        if old is not self.exec_module:
                            setattr(spec.loader, "exec_module", partial(self.exec_module, old))
                        return spec
                finally:
                    self.fullname = None
        return None

    @staticmethod
    def exec_module(old: Callable[[ModuleType], None], module: ModuleType) -> None:
        old(module)
        if module.__name__ in _DISTUTILS_PATCH:
            patch_dist(module)


sys.meta_path.insert(0, _Finder())
