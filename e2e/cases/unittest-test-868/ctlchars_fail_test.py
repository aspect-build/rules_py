import unittest


class AnsiRepr:
    # A subtest parameter whose repr emits an ANSI escape. str(subtest) folds
    # that repr into the testcase *name*, exercising the name/classname
    # sanitization (not just message/detail).
    def __repr__(self) -> str:
        return "\x1b[31mred\x1b[0m"


class ControlCharFailTest(unittest.TestCase):
    def test_ansi_and_nul(self) -> None:
        # A realistic failure message: an ANSI color escape (ESC) plus a NUL
        # byte. Both are forbidden by XML 1.0 even as escapes, so an unsanitized
        # JUnit writer produces a file ElementTree cannot parse.
        self.fail("colored \x1b[31mFAIL\x1b[0m with NUL \x00 here")

    def test_non_latin(self) -> None:
        # Non-latin text forces UTF-8 output; a platform-default (cp1252)
        # encoding would raise UnicodeEncodeError while writing the report.
        self.fail("unicode failure: 🔥 火")

    def test_ansi_subtest_name(self) -> None:
        # The failing subtest's name carries the ANSI-repr parameter, so the
        # control char lands in the <testcase name=...> attribute.
        with self.subTest(value=AnsiRepr()):
            self.fail("subtest with an ANSI parameter repr")
