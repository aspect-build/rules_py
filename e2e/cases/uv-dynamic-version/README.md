# Dynamic package versions

Both the root project and its `dynver` workspace member declare
`dynamic = ["version"]`, so uv writes their `uv.lock` records without a
`version` key. The uv extension must still load the lock and resolve
`dynver` to its `uv.override_package()` target.
