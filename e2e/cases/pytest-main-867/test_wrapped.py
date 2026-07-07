import os


def test_wrapper_setup_ran():
    assert os.environ.get("WRAPPED_SETUP_RAN") == "1"
