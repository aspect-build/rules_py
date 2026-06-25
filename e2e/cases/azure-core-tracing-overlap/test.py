"""Regression: overlapping regular-package trees across wheels.

azure-core 1.38.0 ships `azure/core/` and `azure/core/tracing/` as
REGULAR packages (each has an `__init__.py`); only the `azure/` top
level is a PEP 420 namespace. azure-core-tracing-opentelemetry
1.0.0b11 ships `azure/core/tracing/ext/opentelemetry_span.py` — a
subpackage nested inside a regular package owned by a *different*
wheel.

Regular packages do not merge `__path__` across sys.path entries, so
the namespace `.pth` + addsitedir machinery (see
cases/firebase-admin-import, cases/pth-namespace-547) cannot make
`azure.core.tracing.ext` reachable: once Python resolves
`azure.core.tracing` to azure-core's directory, the `ext/` directory
contributed by the other wheel is invisible unless venv assembly
physically merges the two trees the way a flat `pip install` into one
site-packages would.

Reported by OpenAI from their `oai_otel_init` package, which uses this
exact Azure package pair.
"""

import sys
from importlib.metadata import distributions


def test_azure_core_tracing_ext_import():
    # The failing import from the report: requires `ext/` (from
    # azure-core-tracing-opentelemetry) to be visible inside the
    # `azure.core.tracing` regular package (from azure-core).
    from azure.core.tracing.ext.opentelemetry_span import OpenTelemetrySpan

    assert OpenTelemetrySpan is not None


def test_azure_core_still_intact():
    # The merge must not break azure-core's own modules next to the
    # grafted `ext/` directory.
    from azure.core.settings import settings
    from azure.core.tracing import SpanKind

    assert settings is not None
    assert SpanKind is not None


def test_patched_azure_core_still_merges():
    from azure.core.patched_marker import PATCHED
    from azure.core.tracing.ext.opentelemetry_span import OpenTelemetrySpan

    assert PATCHED is True
    assert OpenTelemetrySpan is not None


def test_patched_azure_core_metadata_is_not_duplicated():
    matches = list(distributions(name="azure-core"))
    assert len(matches) == 1, [str(match.locate_file("")) for match in matches]


def test_azure_core_tracing_is_regular_package():
    """Guard the premise of this test case.

    If a future azure-core converts `azure.core.tracing` into a
    namespace package, this case would silently degrade into a
    duplicate of the pth-namespace-547 coverage. Fail loudly so the
    fixture gets re-pointed at another overlapping pair.
    """
    import azure.core.tracing

    assert azure.core.tracing.__file__ is not None, (
        "azure.core.tracing should be a regular package with __init__.py"
    )


if __name__ == "__main__":
    test_azure_core_tracing_ext_import()
    test_azure_core_still_intact()
    test_patched_azure_core_still_merges()
    test_patched_azure_core_metadata_is_not_duplicated()
    test_azure_core_tracing_is_regular_package()
    print("PASS: azure.core.tracing.ext imports correctly")
    sys.exit(0)
