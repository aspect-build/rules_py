# Copyright 2024 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
A semver version parser

Authored by Ignas, released as part of rules_python.
Removed in 1.5.0, so vendored and used here with thanks.
"""

def _key(version):
    pre_release = version.pre_release
    dev = None
    legacy_dev = False
    if pre_release.startswith("dev."):
        dev_suffix = pre_release[len("dev."):]
        if dev_suffix.isdigit():
            dev = int(dev_suffix)
            pre_release = ""
        else:
            legacy_dev = True
    elif ".dev." in pre_release:
        prefix, _, dev_suffix = pre_release.partition(".dev.")
        if dev_suffix.isdigit():
            dev = int(dev_suffix)
            pre_release = prefix
        else:
            legacy_dev = True

    return (
        version.major,
        version.minor or 0,
        version.patch or 0,
        # non pre-release versions are higher
        version.pre_release == "",
        # then we compare each element of the pre_release tag separately
        tuple([
            (
                i if not i.isdigit() else "",
                # digit values take precedence
                int(i) if i.isdigit() else 0,
            )
            for i in pre_release.split(".")
        ] + ([] if legacy_dev else [
            ("", dev) if dev != None else ("~", 0),
        ])) if version.pre_release else None,
        # And build info is just alphabetic
        version.build,
    )

def _upper(self):
    major = self.major
    minor = self.minor
    patch = self.patch
    build = ""
    pre_release = ""
    version = self.str()

    if patch != None:
        minor = minor + 1
        patch = 0
    elif minor != None:
        major = major + 1
        minor = 0
    else:
        major = major + 1

    return _new(
        major = major,
        minor = minor,
        patch = patch,
        build = build,
        pre_release = pre_release,
        version = "~" + version,
    )

def _new(*, major, minor, patch, pre_release, build, version = None):
    # buildifier: disable=uninitialized
    self = struct(
        major = int(major),
        minor = None if minor == None else int(minor),
        # NOTE: this is called `micro` in the Python interpreter versioning scheme
        patch = None if patch == None else int(patch),
        pre_release = pre_release,
        build = build,
        # buildifier: disable=uninitialized
        key = lambda: _key(self),
        str = lambda: version,
        upper = lambda: _upper(self),
    )
    return self

def semver(version):
    """Parse the semver version and return the values as a struct.

    Args:
        version: {type}`str` the version string.

    Returns:
        A {type}`struct` with `major`, `minor`, `patch` and `build` attributes.
    """

    major, _, tail = version.partition(".")
    tail, _, build = tail.partition("+")
    minor, _, tail = tail.partition(".")
    patch, _, pre_release = tail.partition("-")

    release = patch or minor
    remainder = ""
    if patch and not minor.isdigit():
        release = minor
        remainder = patch

    suffix = pre_release
    split_release = False
    if not release.isdigit():
        end = 0
        for char in release.elems():
            if not char.isdigit():
                break
            end += 1

        suffix = ".".join([
            part
            for part in [release[end:].strip("-_."), remainder, pre_release]
            if part
        ])
        split_release = True

    # Interpreter full versions use dev/a/b/rc suffixes; post-release forms
    # are not emitted by PBS and intentionally retain the legacy behavior.
    if suffix:
        suffix = suffix.lower().strip("-_.")
        original_suffix = suffix
        suffix, has_dev, dev = suffix.partition("dev")
        suffix = suffix.strip("-_.")
        dev = dev.strip("-_.") or "0"
        if has_dev and not dev.isdigit():
            has_dev = ""
            suffix = original_suffix

        matched = False
        if has_dev and not suffix:
            pre_release = "dev.{}".format(int(dev))
            matched = True

        for spelling, normalized in [
            ("alpha", "a"),
            ("beta", "b"),
            ("preview", "rc"),
            ("pre", "rc"),
            ("rc", "rc"),
            ("c", "rc"),
            ("a", "a"),
            ("b", "b"),
        ]:
            if suffix.startswith(spelling):
                number = suffix[len(spelling):].strip("-_.") or "0"
                if number.isdigit():
                    pre_release = "{}.{}".format(normalized, int(number))
                    if has_dev:
                        pre_release += ".dev.{}".format(int(dev))
                    matched = True
                    break

        if matched and split_release:
            if release == patch:
                patch = patch[:end]
            else:
                minor = minor[:end]
                patch = ""

    return _new(
        major = int(major),
        minor = int(minor) if minor.isdigit() else None,
        patch = int(patch) if patch.isdigit() else None,
        build = build,
        pre_release = pre_release,
        version = version,
    )
