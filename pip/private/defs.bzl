def possible_coordinate(python_tag, platform_tag, abi_tag):
    """
    Decide if a {python_tag}-{platform_tag}-{abi_tag} interpreter triple is possible.

    For instance py2-none-cp314 would be an incoherent coordinate. The python
    tag and the ABI tag clash in an impossible/unreachable way.

    Due to compressed tag sets it's possible that we'd see such a thing and we
    want to ignore it if we do.
    """

    if abi_tag == "any":
        return True

    if
