"version information. replaced with stamped info with each release"

# Automagically "stamped" by git during `git archive` thanks to `export-subst` line in .gitattributes.
# See https://git-scm.com/docs/git-archive#Documentation/git-archive.txt-export-subst
_VERSION_PRIVATE = "$Format:%(describe:tags=true)$"

VERSION = "0.0.0" if _VERSION_PRIVATE.startswith("$Format") else _VERSION_PRIVATE.replace("v", "", 1)

# Whether rules_py is a pre-release, and therefore has no release artifacts to download.
# NB: When GitHub runs `git archive` to serve a source archive file,
# it honors our .gitattributes and stamps this file, e.g.
# _VERSION_PRIVATE = "v2.0.3-7-g57bfe2c1"
# From https://git-scm.com/docs/git-describe:
# > The "g" prefix stands for "git"
IS_PRERELEASE = VERSION == "0.0.0" or VERSION.find("g") >= 0
