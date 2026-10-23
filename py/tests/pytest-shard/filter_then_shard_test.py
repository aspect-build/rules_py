import pytest


@pytest.mark.parametrize(
    "name",
    ["keep0", "drop1", "keep2", "drop3", "keep4", "drop5", "keep6", "drop7"],
)
def test_case(name: str) -> None:
    assert name.startswith("keep")
