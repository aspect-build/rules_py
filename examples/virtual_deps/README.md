# virtual_deps

The example shows how to use `virtual_deps` feature.

 - `greet` is a library that has a virtual dependency on `cowsay`
 - `cowsnake` is a library that implements some of the `cowsay` API
 - `app` is a binary that uses `greet` and resolves the `cowsay` virtual dependency
 - `app_snake` is like `app`, but swaps out `cowsay` for `cowsnake`!
 - `pytest_test` tests `greet` using a resolved `cowsay`
