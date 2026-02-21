#!/usr/bin/env python3

from generate import get_importable_module_name, find_unique_shallowest_prefixes

def test_parse_names():
    assert get_importable_module_name("foo.py") == "foo"
    assert get_importable_module_name("foo/__init__.py") == "foo"
    assert get_importable_module_name("foo.cpython-311-x86_64-linux-gnu.so") == "foo"

    
# Case 1 -- bunch of basic examples
def test_basic():
    assert find_unique_shallowest_prefixes([
    ("foo", "foo"),
    ("bar", "bar"),
    ("baz", "baz"),
]) == {
    "foo": "foo",
    "bar": "bar",
    "baz": "baz",
}

    # Case 2 -- these get stripped to basic prefixes
    assert find_unique_shallowest_prefixes([
    ("foo.a", "foo"),
    ("foo.b", "foo"),
    ("foo.c", "foo"),
    ("bar.d", "bar"),
    ("bar.e", "bar"),
    ("baz.f", "baz"),
]) == {
    "foo": "foo",
    "bar": "bar",
    "baz": "baz",
}

    # Case 3 -- text prefixes don't impact splitting
    assert find_unique_shallowest_prefixes([
    ("foo_a", "foo-a"),
    ("foo_b", "foo-b"),
    ("foo_c", "foo-c"),
]) == {
    "foo_a": "foo-a",
    "foo_b": "foo-b",
    "foo_c": "foo-c",
}

    # Case 4 -- Shared package prefixes get handled
    assert find_unique_shallowest_prefixes([
    ("foo.a", "foo-a"),
    ("foo.b", "foo-b"),
    ("foo.c", "foo-c"),
]) == {
    "foo.a": "foo-a",
    "foo.b": "foo-b",
    "foo.c": "foo-c",
}
    
    # Case 5 -- Having a base package doesn't cause problems
    assert find_unique_shallowest_prefixes([
    ("foo", "foo"),
    ("foo.a", "foo"),
    ("foo.b.a", "foo"),
    ("foo.c.d", "foo"),
]) == {
    "foo": "foo",
}

    # Case 6 -- Overlapping prefixes with distinct packages
    assert find_unique_shallowest_prefixes([
    ("requests", "requests"),
    ("requests.utils", "requests"),
    ("requests_toolbelt", "requests_toolbelt"),
    ("requests_toolbelt.adapters", "requests_toolbelt"),
]) == {
    "requests": "requests",
    "requests_toolbelt": "requests_toolbelt",
}

    # Case 7 -- Sub-packages of the same parent
    assert find_unique_shallowest_prefixes([
    ("mypackage", "mypackage"),
    ("mypackage.submodule", "mypackage"),
    ("mypackage.submodule.nested", "mypackage"),
]) == {
    "mypackage": "mypackage",
}

    # Case 8 -- Module name same as package name
    assert find_unique_shallowest_prefixes([
    ("my_package", "my_package"),
    ("my_package.module_a", "my_package"),
    ("my_package.module_b.nested", "my_package"),
    ("my_package_another", "my_package_another"),
]) == {
    "my_package": "my_package",
    "my_package_another": "my_package_another",
}

    assert find_unique_shallowest_prefixes([
    ('jupyter_server', 'jupyter_server'),
    ('jupyter_server.config_manager', 'jupyter_server'),
    ('jupyter_server.log', 'jupyter_server'),
    ('jupyter_server.pytest_plugin', 'jupyter_server'),
    ('jupyter_server.serverapp', 'jupyter_server'),
    ('jupyter_server.traittypes', 'jupyter_server'),
    ('jupyter_server.transutils', 'jupyter_server'),
    ('jupyter_server.utils', 'jupyter_server'),
    ('jupyter_server.auth', 'jupyter_server'),
    ('jupyter_server.auth.authorizer', 'jupyter_server'),
    ('jupyter_server.auth.decorator', 'jupyter_server'),
    ('jupyter_server.auth.identity', 'jupyter_server'),
    ('jupyter_server.auth.login', 'jupyter_server'),
    ('jupyter_server.auth.logout', 'jupyter_server'),
    ('jupyter_server.auth.security', 'jupyter_server'),
    ('jupyter_server.auth.utils', 'jupyter_server'),
    ('jupyter_server.base', 'jupyter_server'),
    ('jupyter_server.base.call_context', 'jupyter_server'),
    ('jupyter_server.base.handlers', 'jupyter_server'),
    ('jupyter_server.base.websocket', 'jupyter_server'),
    ('jupyter_server.base.zmqhandlers', 'jupyter_server'),
    ('jupyter_server.extension', 'jupyter_server'),
    ('jupyter_server.extension.application', 'jupyter_server'),
    ('jupyter_server.extension.config', 'jupyter_server'),
    ('jupyter_server.extension.handler', 'jupyter_server'),
    ('jupyter_server.extension.manager', 'jupyter_server'),
    ('jupyter_server.extension.serverextension', 'jupyter_server'),
    ('jupyter_server.extension.utils', 'jupyter_server'),
    ('jupyter_server.files', 'jupyter_server'),
    ('jupyter_server.files.handlers', 'jupyter_server'),
    ('jupyter_server.gateway', 'jupyter_server'),
    ('jupyter_server.gateway.connections', 'jupyter_server'),
    ('jupyter_server.gateway.gateway_client', 'jupyter_server'),
    ('jupyter_server.gateway.handlers', 'jupyter_server'),
    ('jupyter_server.gateway.managers', 'jupyter_server'),
    ('jupyter_server.i18n', 'jupyter_server'),
    ('jupyter_server.kernelspecs', 'jupyter_server'),
    ('jupyter_server.kernelspecs.handlers', 'jupyter_server'),
    ('jupyter_server.nbconvert', 'jupyter_server'),
    ('jupyter_server.nbconvert.handlers', 'jupyter_server'),
    ('jupyter_server.prometheus', 'jupyter_server'),
    ('jupyter_server.prometheus.log_functions', 'jupyter_server'),
    ('jupyter_server.prometheus.metrics', 'jupyter_server'),
    ('jupyter_server.services', 'jupyter_server'),
    ('jupyter_server.services.shutdown', 'jupyter_server'),
    ('jupyter_server.services.api', 'jupyter_server'),
    ('jupyter_server.services.api.handlers', 'jupyter_server'),
    ('jupyter_server.services.config', 'jupyter_server'),
    ('jupyter_server.services.config.handlers', 'jupyter_server'),
    ('jupyter_server.services.config.manager', 'jupyter_server'),
    ('jupyter_server.services.contents', 'jupyter_server'),
    ('jupyter_server.services.contents.checkpoints', 'jupyter_server'),
    ('jupyter_server.services.contents.filecheckpoints', 'jupyter_server'),
    ('jupyter_server.services.contents.fileio', 'jupyter_server'),
    ('jupyter_server.services.contents.filemanager', 'jupyter_server'),
    ('jupyter_server.services.contents.handlers', 'jupyter_server'),
    ('jupyter_server.services.contents.largefilemanager', 'jupyter_server'),
    ('jupyter_server.services.contents.manager', 'jupyter_server'),
    ('jupyter_server.services.events', 'jupyter_server'),
    ('jupyter_server.services.events.handlers', 'jupyter_server'),
    ('jupyter_server.services.kernels', 'jupyter_server'),
    ('jupyter_server.services.kernels.handlers', 'jupyter_server'),
    ('jupyter_server.services.kernels.kernelmanager', 'jupyter_server'),
    ('jupyter_server.services.kernels.websocket', 'jupyter_server'),
    ('jupyter_server.services.kernels.connection', 'jupyter_server'),
    ('jupyter_server.services.kernels.connection.abc', 'jupyter_server'),
    ('jupyter_server.services.kernels.connection.base', 'jupyter_server'),
    ('jupyter_server.services.kernels.connection.channels', 'jupyter_server'),
    ('jupyter_server.services.kernelspecs', 'jupyter_server'),
    ('jupyter_server.services.kernelspecs.handlers', 'jupyter_server'),
    ('jupyter_server.services.nbconvert', 'jupyter_server'),
    ('jupyter_server.services.nbconvert.handlers', 'jupyter_server'),
    ('jupyter_server.services.security', 'jupyter_server'),
    ('jupyter_server.services.security.handlers', 'jupyter_server'),
    ('jupyter_server.services.sessions', 'jupyter_server'),
    ('jupyter_server.services.sessions.handlers', 'jupyter_server'),
    ('jupyter_server.services.sessions.sessionmanager', 'jupyter_server'),
    ('jupyter_server.terminal', 'jupyter_server'),
    ('jupyter_server.terminal.api_handlers', 'jupyter_server'),
    ('jupyter_server.terminal.handlers', 'jupyter_server'),
    ('jupyter_server.terminal.terminalmanager', 'jupyter_server'),
    ('jupyter_server.view', 'jupyter_server'),
    ('jupyter_server.view.handlers', 'jupyter_server'),

    ('jupyter_server_terminals', 'jupyter_server_terminals'),
    ('jupyter_server_terminals.api_handlers', 'jupyter_server_terminals'),
    ('jupyter_server_terminals.app', 'jupyter_server_terminals'),
    ('jupyter_server_terminals.base', 'jupyter_server_terminals'),
    ('jupyter_server_terminals.handlers', 'jupyter_server_terminals'),
    ('jupyter_server_terminals.terminalmanager', 'jupyter_server_terminals'),
]) == {
    "jupyter_server": "jupyter_server",
    "jupyter_server_terminals": "jupyter_server_terminals",
}
