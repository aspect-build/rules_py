"""Regression test for #530: pytest-mock must work with py_test and py_venv_test.

Exercises the ``mocker`` fixture provided by the pytest-mock plugin, which
requires pytest plugin discovery to function correctly.
"""


def _real_function():
    return 42


def test_mocker_patch(mocker):
    """The mocker fixture should be available and functional."""
    mocker.patch(f"{__name__}._real_function", return_value=99)
    assert _real_function() == 99


def test_mocker_spy(mocker):
    """mocker.spy should wrap a real function and track calls."""
    spy = mocker.spy(__import__("os.path", fromlist=["exists"]), "exists")
    import os.path
    os.path.exists("/")
    spy.assert_called_once_with("/")


def test_mocker_mock_object(mocker):
    """mocker.MagicMock should create mock objects."""
    mock = mocker.MagicMock()
    mock.some_method.return_value = "hello"
    assert mock.some_method() == "hello"
    mock.some_method.assert_called_once()
