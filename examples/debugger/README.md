# Debugger (debugpy) Example

This example demonstrates how to attach a DAP-compatible debugger (VSCode,
PyCharm, etc.) to a `py_binary` built with `rules_py`.

## The Problem

IDEs like PyCharm expect to control the Python process startup for debugging,
but Bazel's hermetic launcher scripts break that assumption. The workaround
is to use [debugpy](https://github.com/microsoft/debugpy), a network-based
debug adapter that the application starts itself, allowing the IDE to attach
over TCP after the process is running.

This approach works with any IDE that supports the
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
(DAP): VSCode, PyCharm (with debugpy plugin), Neovim (nvim-dap), Emacs
(dap-mode), etc.

## How It Works

The structure mirrors the [dev_deps example](../dev_deps/), using PEP 735
dependency groups and a `string_flag` to conditionally include `debugpy`.
The key addition is that the binary's **entrypoint itself** is swapped in
debug mode.

### 1. Dependency groups in `pyproject.toml`

```toml
[dependency-groups]
prod = ["flask"]
debug = [
    {include-group = "prod"},
    "debugpy",
]
```

### 2. Auto-generated debug wrapper

The `py_debuggable_binary` macro generates a debugpy wrapper from a
template (`_debug_main.py.tpl`). The wrapper starts a DAP listener, then
uses `runpy.run_module()` to execute the real entrypoint. You don't need
to write any debugpy boilerplate — just specify your normal `main`.

### 3. The wrapper macro (`defs.bzl`)

```starlark
py_debuggable_binary(
    name = "app",
    srcs = ["app.py"],
    main = "app.py",
    deps = ["@pypi//flask"],
    debug_deps = ["@pypi//debugpy"],
)
```

In debug mode (the default), the macro generates a wrapper that starts
debugpy and then runs `app.py`. In prod mode, `app.py` is the entrypoint
directly and `debugpy` is absent.

### 4. Venv selection via `.bazelrc`

```
common --@pypi//venv=debug

common:release --@pypi//venv=prod
common:release --//:mode=prod
```

## Running the example

```sh
cd examples/debugger

# Debug mode (default) — debugpy listener on 127.0.0.1:5678:
bazel run //:app

# Wait for IDE to attach before running app code:
DEBUGPY_WAIT=1 bazel run //:app

# Release mode — no debugpy, app.py runs directly:
bazel run //:app --config=release
```

## Attaching your IDE

### VSCode

Add to `.vscode/launch.json`:

```json
{
    "name": "Attach to Bazel py_binary",
    "type": "debugpy",
    "request": "attach",
    "connect": {"host": "127.0.0.1", "port": 5678}
}
```

Then `DEBUGPY_WAIT=1 bazel run //:app` and press F5 in VSCode.

### PyCharm

Use **Run > Attach to Process** or create a **Python Debug Server**
run configuration pointing to `127.0.0.1:5678`. Requires the debugpy
plugin (see [PY-63403](https://youtrack.jetbrains.com/issue/PY-63403)).
