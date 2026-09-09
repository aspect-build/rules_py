import pytest


@pytest.fixture
def shared_value() -> str:
    return "from conftest"
