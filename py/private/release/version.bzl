"version information. replaced with stamped info with each release"

# Automagically "stamped" by git during `git archive` thanks to `export-subst` line in .gitattributes.
# See https://git-scm.com/docs/git-archive#Documentation/git-archive.txt-export-subst
_VERSION_PRIVATE = "$Format:%(describe:tags=true)$"

VERSION = "0.0.0" if _VERSION_PRIVATE.startswith("$Format") else _VERSION_PRIVATE.replace("v", "", 1)
