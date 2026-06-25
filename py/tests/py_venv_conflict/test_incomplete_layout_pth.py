import sys


complete_count = sys.path.count("rules_py_pth_complete")
incomplete_count = sys.path.count("rules_py_pth_incomplete")
suppressed_count = sys.path.count("rules_py_pth_suppressed")

assert complete_count > 0, "complete-layout root .pth did not execute"
assert suppressed_count == 0, (
    "losing complete-layout root .pth was not suppressed",
    suppressed_count,
)
assert incomplete_count == complete_count, (
    "incomplete layout added root .pth executions",
    complete_count,
    incomplete_count,
)
