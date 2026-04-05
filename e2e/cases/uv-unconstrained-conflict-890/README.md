# Unconstrained multi-version conflict resolution

When two conflicting dependency groups both include a package WITHOUT a version
specifier (e.g. just `"build"`), and the lockfile resolves that package to
different versions per group, the resolution logic must use the lockfile's
per-group resolved versions to disambiguate.

The lockfile is intentionally stale relative to the pyproject.toml — it contains
two versions of `build` (1.3.0 and 1.4.0) mapped to different groups, which is
the scenario that triggered the original bug.
