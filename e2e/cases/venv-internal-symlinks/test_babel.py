import os
import sys


def test_babel_import():
    import babel
    import babel.messages
    assert babel.__file__ is not None, "babel should be a real module with __file__"
    assert os.path.exists(babel.__file__), f"babel.__file__ should exist: {babel.__file__}"


def test_babel_locale_data():
    from babel import localedata
    available = localedata.locale_identifiers()
    assert len(available) > 0, "babel should have available locales"
    from babel.core import Locale
    locale = Locale.parse("en_US")
    assert locale.language == "en", "locale language should be 'en'"
    assert locale.territory == "US", "locale territory should be 'US'"


def test_no_dangling_symlinks():
    import babel

    babel_dir = os.path.dirname(babel.__file__)
    dangling = []

    for root, dirs, files in os.walk(babel_dir):
        for name in files + dirs:
            full_path = os.path.join(root, name)
            if os.path.islink(full_path):
                target = os.readlink(full_path)
                if not os.path.exists(full_path):
                    dangling.append((full_path, target))

    assert len(dangling) == 0, f"Found dangling symlinks: {dangling}"


if __name__ == "__main__":
    test_babel_import()
    test_babel_locale_data()
    test_no_dangling_symlinks()
    print("PASS: internal symlinks handling works correctly")
