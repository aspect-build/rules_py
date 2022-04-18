def dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]
