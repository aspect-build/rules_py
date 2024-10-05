# Using rules_py on windows

## Dev dependencies / issues

rattler_install_packages includes some very long filenames, and this package is configured in cargo.toml to fetch via git. If there are errors on retrieval, try running:
```
git config --system core.longpaths true
```

Can we download rattler_install_packages http (archive.zip) instead?

### Output base

rules_rust generates very long paths. Use --user_output_root=d:\b to partially mitigate.

### zstd crate

`Running cargo build script zstd-sys` fails to build on msvc. I'm not sure why. Perhaps though if we can generate this in some other way it can be a non-issue.

```
error occurred: Command "c:/apps/MVS174/VC/Tools/MSVC/14.40.33521/bin/HostX64/x64/cl.exe" "-nologo" "-MD" "-Z7" "-Brepro" "/nologo" "/DCOMPILER_MSVC" "/DNOMINMAX" "/D_WIN32_WINNT=0x0601" "/D_CRT_SECURE_NO_DEPRECATE" "/D_CRT_SECURE_NO_WARNINGS" "/bigobj" "/Zm500" "/EHsc" "/wd4351" "/wd4291" "/wd4250" "/wd4996" "/showIncludes" "/MD" "/Od" "/Z7" "/wd4117" "-D__DATE__=\"redacted\"" "-D__TIMESTAMP__=\"redacted\"" "-D__TIME__=\"redacted\"" "-I" "zstd/lib/" "-I" "zstd/lib/common" "-I" "zstd/lib/legacy" "-fvisibility=hidden" "-DZSTD_DISABLE_ASM=" "-DZSTD_LIB_DEPRECATED=0" "-DXXH_PRIVATE_API=" "-DZSTDLIB_VISIBILITY=" "-DZDICTLIB_VISIBILITY=" "-DZSTDERRORLIB_VISIBILITY=" "-DZSTD_LEGACY_SUPPORT=1" "-FoD:\\b\\jkggyhq2\\execroot\\aspect_rules_py\\bazel-out/x64_windows-fastbuild/bin/external/crate_index__zstd-sys-2.0.9-zstd.1.5.5/zstd-sys_build_script.out_dir\\zstd/lib/dictBuilder\\zdict.o" "-c" "zstd/lib/dictBuilder\\zdict.c" with args "cl.exe" did not execute successfully (status code exit code: 2).
```

## Test cases

```
bazel --output_user_root=d:\b test //...
```

Three test cases are passing:

```
//py/tests/import-pathing:imp_path_can_not_be_absolute                   PASSED in 0.4s
//py/tests/import-pathing:imp_path_that_breaks_workspace_root            PASSED in 0.4s
//py/tests/import-pathing:py_library_import_pathing_test_suite_test_0    PASSED in 0.4s
```