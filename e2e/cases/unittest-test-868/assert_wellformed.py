import sys
import xml.etree.ElementTree as ET

# Parse the JUnit XML produced by the unittest driver. ET.parse raises on any
# XML-1.0-forbidden byte (unsanitized control chars / NUL) and on encoding
# errors, so a clean parse proves the writer sanitized and wrote UTF-8.
tree = ET.parse(sys.argv[1])
root = tree.getroot()
failures = sum(int(ts.get("failures", "0")) for ts in root.iter("testsuite"))
# Two failing methods plus one failing subtest whose ANSI-repr parameter lands
# in the testcase name — a clean parse proves name/message/detail were all
# sanitized.
if failures < 3:
    sys.exit("expected >= 3 recorded failures, got %d" % failures)
print("OK: well-formed JUnit XML with failures=%d" % failures)
