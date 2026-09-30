"""The ty aspect and its test rules, as a rules_lint user would declare them."""

load("@aspect_rules_lint//lint:lint_test.bzl", "lint_test")
load("@aspect_rules_lint//lint:ty.bzl", "lint_ty_aspect")
load("@aspect_rules_py//py:defs.bzl", "py_test")

ty = lint_ty_aspect(
    binary = Label("@aspect_rules_lint//lint:ty_bin"),
    config = Label("//:ty.toml"),
)

ty_test = lint_test(aspect = ty)

def _ty_report_impl(ctx):
    reports = [
        file
        for file in ctx.attr.src[OutputGroupInfo].rules_lint_human.to_list()
        if file.extension == "out"
    ]
    return [DefaultInfo(files = depset(reports))]

# Exposes ty's human-readable report on `src` as an ordinary file, so a test
# can depend on it.
ty_report = rule(
    implementation = _ty_report_impl,
    attrs = {
        "src": attr.label(aspects = [ty], mandatory = True),
    },
)

def ty_diagnostic_test(name, src, expected, **kwargs):
    """Asserts that ty's report on `src` contains `expected`.

    Args:
        name: Name of the test.
        src: The target ty checks.
        expected: Text the report must contain.
        **kwargs: Forwarded to the underlying `py_test`.
    """
    report = name + ".report"
    ty_report(
        name = report,
        src = src,
        testonly = True,
    )
    py_test(
        name = name,
        srcs = [Label("//tools/lint:expect_diagnostic.py")],
        main = Label("//tools/lint:expect_diagnostic.py"),
        data = [report],
        env = {
            "EXPECTED_DIAGNOSTIC": expected,
            "TY_REPORT": "$(rootpath :{})".format(report),
        },
        **kwargs
    )
