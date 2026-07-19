import packaging


def get_packaging_version() -> str:
    return packaging.__version__
