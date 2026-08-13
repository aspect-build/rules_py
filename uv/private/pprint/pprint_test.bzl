load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "pprint")

def _test_pprint_dict(ctx):
    env = unittest.begin(ctx)
    test_dict = {"a": 1, "b": 2}
    expected = """{
    "a": 1,
    "b": 2,
}"""
    asserts.equals(env, expected, pprint(test_dict))
    return unittest.end(env)

pprint_dict_test = unittest.make(_test_pprint_dict)

def _test_pprint_list(ctx):
    env = unittest.begin(ctx)
    test_list = [1, "foo", True]
    expected = """[
    1,
    "foo",
    True,
]"""
    asserts.equals(env, expected, pprint(test_list))
    return unittest.end(env)

pprint_list_test = unittest.make(_test_pprint_list)

def _test_pprint_struct(ctx):
    env = unittest.begin(ctx)
    test_struct = struct(a = 1, b = "foo")
    expected = """struct(
    a = 1,
    b = "foo",
)"""
    asserts.equals(env, expected, pprint(test_struct))
    return unittest.end(env)

pprint_struct_test = unittest.make(_test_pprint_struct)

def _test_pprint_nested(ctx):
    env = unittest.begin(ctx)
    test_nested = {"a": [1, 2], "b": struct(c = {"d": 3})}
    expected = """{
    "a": [
        1,
        2,
    ],
    "b": struct(
        c = {
            "d": 3,
        },
    ),
}"""
    asserts.equals(env, expected, pprint(test_nested))
    return unittest.end(env)

pprint_nested_test = unittest.make(_test_pprint_nested)

def pprint_test_suite():
    unittest.suite(
        "pprint_tests",
        pprint_dict_test,
        pprint_list_test,
        pprint_struct_test,
        pprint_nested_test,
    )
