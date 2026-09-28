"""The ty aspect and its test rule, as a rules_lint user would declare them."""

load("@aspect_rules_lint//lint:lint_test.bzl", "lint_test")
load("@aspect_rules_lint//lint:ty.bzl", "lint_ty_aspect")

ty = lint_ty_aspect(
    binary = Label("@aspect_rules_lint//lint:ty_bin"),
    config = Label("//:ty.toml"),
)

ty_test = lint_test(aspect = ty)
