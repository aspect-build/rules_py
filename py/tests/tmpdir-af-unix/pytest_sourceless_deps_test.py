"""Under pyc_only, pytest's own srcs are source while dependencies are bytecode only."""

import inspect

import pytest

import af_unix_probe


def test_collected_source_is_retained() -> None:
    assert __file__.endswith(".py")
    assert inspect.getsource(test_collected_source_is_retained)


def test_dependency_is_sourceless() -> None:
    assert af_unix_probe.__file__.endswith(".pyc")
    with pytest.raises(OSError):
        inspect.getsource(af_unix_probe)
