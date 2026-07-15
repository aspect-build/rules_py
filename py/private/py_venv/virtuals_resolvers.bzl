"""Wheel collision and namespace merge resolution for venv site-packages.

Walks PyWheelsInfo.wheels and produces merge plans that the venv
assembler turns into per-entry symlinks, physical merges, and
console-script wrappers.

Extracted from the former ``venv.bzl`` monolith. Pure Starlark — no
external loads, operates solely on wheel struct fields and ``ctx.label``.
"""

def resolve_wheel_collisions(ctx, wheels, package_collisions):
    """Walk PyWheelsInfo.wheels and produce merge plans for site-packages + bin/.

    Three kinds of collision get checked:

    * **Top-level in site-packages.** Multiple wheels claiming the same
      top-level name. When ALL contributing wheels flag the name as a
      PEP 420 namespace package (no `__init__.py` at that level), the
      collision is benign — merge the namespace CONCRETELY: a real
      `site-packages/<tl>/` directory whose members are per-entry
      symlinks into each contributing wheel (from the wheels'
      `namespace_entries` metadata). Runtime imports would also work via
      `.pth` + `addsitedir` alone, but tools that inspect site-packages
      directly — mypy, pyright — never execute `.pth` files, so without
      a concrete entry they miss the package and its `py.typed` markers
      entirely. Wheels lacking entry metadata (hand-written
      `py_unpacked_wheel`) keep the historical `.pth`-only fallback,
      where Python's namespace machinery merges contributions at
      runtime. Otherwise apply `package_collisions` policy. When every
      claimant identifies the top-level as a directory,
      permissive modes physically merge it: Python binds a regular package
      to the first directory on sys.path, so a .pth fallback would hide the
      other wheels' unique children. A root carrying a native library stays
      on a direct wheel projection: copying it would change the library's
      physical origin and can break origin-relative sibling lookup. Distinct
      losing distributions keep their whole-wheel fallback so regular
      packages that extend __path__ can still see a native namespace graft;
      only a loser with duplicate declared metadata is suppressed.

      Within an all-namespace top-level there's one shape `.pth` +
      `addsitedir` cannot handle: a REGULAR package spanning wheels.
      E.g. azure-core owns `azure/core/` (has `__init__.py`) while
      azure-core-tracing-opentelemetry installs
      `azure/core/tracing/ext/opentelemetry_span/` into that same tree.
      Python locks a regular package's `__path__` to the first
      directory found, so the second wheel's graft is unreachable. We
      detect this by cross-referencing each wheel's `regular_roots`
      against the other claimants' `namespace_dirs` skeletons, and
      return the minimal conflicted roots as `merge_groups` — the
      caller physically merges those subtrees (what a flat
      `pip install` would have produced).

    * **Declared distribution metadata in site-packages.** Metadata discovery
      scans every `sys.path` entry instead of stopping at the first match.
      Preserve the existing exact-entry collision precedence, but project the
      selected `*.dist-info` and `*.egg-info` entry only when that wheel needs
      no whole-wheel fallback. Reject an exact-entry collision when a losing
      claimant remains on fallback and therefore cannot be suppressed.

    * **Console-script name in bin/.** Apply `package_collisions` directly
      — no namespace equivalent.

    Returns:
      top_level_to_site_pkgs: dict {site_packages_relative_path: site_packages_rfpath}
          — keys are import roots, `/`-joined deeper paths (e.g.
          `jaraco/functools`) for merged namespace packages, and distribution
          metadata entries owned by fully covered wheels.
      fully_covered_site_pkgs: dict[str, True] — site-packages paths whose
          declared import roots are all projected, merged, or deliberately
          suppressed by collision policy — safe to drop from the .pth
          fallback.
      console_scripts_map: dict {script_name: struct(module, func)} after
          collision resolution.
      merge_groups: list of struct(root, site_packages_list) — package dirs
          (site-packages-relative paths) that need a physical merge, with the
          contributing wheels' site-packages paths in wheel traversal order.
    """

    def _complain(what, name, a, b):
        msg = "Package collision in {target}: {what} `{name}` is provided by both {a} and {b}.".format(
            target = str(ctx.label),
            what = what,
            name = name,
            a = a,
            b = b,
        )
        if package_collisions == "error":
            fail(msg + "\nSet `package_collisions = \"warning\"` or \"ignore\" to downgrade.")
        elif package_collisions == "warning":
            # buildifier: disable=print
            print(msg)

    def _distinct_claimants(keys):
        """Dedup ordered claimant keys, preserving first-claim order.

        Collision precedence is "last distinct claimant wins": the final
        element is the winner, everything before it is a loser.
        """
        return {k: True for k in keys}.keys()

    def _distinct_by_sp(claimants):
        """Last claim struct per claimant, keyed in first-claim (precedence) order.

        Starlark dicts preserve insertion order and overwriting a key keeps
        its position, so .keys() is exactly the distinct-claimant precedence
        chain (last element wins) and .values() the matching claim structs.
        """
        return {c.site_packages: c for c in claimants}

    def _complain_chain(what, name, distinct):
        """Complain once per takeover along a distinct-claimant chain."""
        for i in range(1, len(distinct)):
            _complain(what, name, distinct[i - 1], distinct[i])

    def _under(path, roots):
        """True when path equals or sits below any of roots."""
        for root in roots:
            if path == root or path.startswith(root + "/"):
                return True
        return False

    def _covers(root, paths):
        """True when any of paths equals or sits below root."""
        for p in paths:
            if p == root or p.startswith(root + "/"):
                return True
        return False

    def _shallowest(roots):
        """Minimal cover of roots: drop any root nested below another.

        Lexicographic order puts an ancestor before its descendants, so a
        single pass over the sorted roots suffices.
        """
        out = []
        for root in sorted(roots):
            if not _under(root, out):
                out.append(root)
        return out

    # Pass 1: bucket claimants per import root, distribution metadata entry,
    # and console-script name. The per-wheel claim structs are precomputed
    # by make_wheel_record, so this pass only merges them per closure.
    tl_claimants = {}  # tl -> list of struct(site_packages, is_ns, is_dir, is_native, ns_entries)
    metadata_claimants = {}  # metadata entry -> ordered site_packages paths
    cs_claimants = {}  # name -> list of struct(site_packages, module, func)
    wheel_by_sp = {}  # site_packages_rfpath -> wheel struct
    for w in wheels:
        wheel_by_sp[w.site_packages_rfpath] = w
        for tl in w.metadata_top_levels:
            metadata_claimants.setdefault(tl, []).append(w.site_packages_rfpath)
        for tl, claim in w.tl_claims:
            tl_claimants.setdefault(tl, []).append(claim)
        for name, claim in w.cs_claims:
            cs_claimants.setdefault(name, []).append(claim)

    # A native collision cannot both keep every wheel-relative root and merge
    # them into one concrete venv directory. Distinct distributions may keep a
    # losing wheel on the .pth fallback, which also preserves namespace grafts
    # for regular packages that extend __path__. A duplicate declared metadata
    # entry makes every losing fallback unsound because metadata discovery
    # scans every sys.path entry. Cover only prior duplicate-metadata
    # claimants; the selected claimant still keeps fallback when needed.
    duplicate_metadata_loser_sps = {
        loser: True
        for claimants in metadata_claimants.values()
        for loser in _distinct_claimants(claimants)[:-1]
    }

    # Pass 2: resolve top-levels. Track which (site_packages, tl) pairs
    # we SKIPPED (left to the .pth fallback) and which claims were fully
    # COVERED by projection, merge, or deliberate collision suppression, so
    # pass 3 can decide which wheels are fully covered.
    top_level_to_site_pkgs = {}
    skipped_per_wheel = {}
    covered_per_wheel = {}
    merge_groups = []
    conflicted_roots = {}  # root path -> True (regular package spanning wheels)
    ns_claimant_sps = {}  # sp -> True, wheels in any all-namespace collision

    def _own_entries(claimants_with_entries, tl, exclude_roots):
        """Per-entry merge over the entries-bearing claimants of tl.

        The last distinct wheel to claim an entry wins. An earlier wheel
        shipping the same entry is a genuine collision (same subpackage
        twice) — complain per policy and leave the earlier claimant on
        the .pth path. Entries under exclude_roots are owned by either a
        direct native projection or a physical merge and are not merged
        here.
        (An entryless claimant shipping the same subpackage can't be
        detected here; the concrete symlink wins over its .pth portion.)
        """
        entry_owner = {}
        for c in claimants_with_entries:
            for entry in c.ns_entries:
                if _under(entry, exclude_roots):
                    continue
                prior = entry_owner.get(entry)
                if prior == None:
                    entry_owner[entry] = c
                elif prior.site_packages != c.site_packages:
                    _complain("namespace entry", entry, prior.site_packages, c.site_packages)
                    skipped_per_wheel.setdefault(prior.site_packages, {})[tl] = True
                    entry_owner[entry] = c
        return entry_owner

    for tl, claimants in tl_claimants.items():
        distinct_sp = _distinct_by_sp(claimants)
        if len(distinct_sp) == 1:
            top_level_to_site_pkgs[tl] = claimants[0].site_packages
            continue

        is_ns = [c.is_ns for c in claimants]
        all_namespace = all(is_ns)
        any_namespace = any(is_ns)
        if all_namespace:
            # Deep-overlap scan first: a regular root of one claimant
            # appearing in another claimant's namespace skeleton (B
            # installs files below it) or as another's own regular root
            # marks a REGULAR package spanning wheels (azure-core +
            # azure-core-tracing-opentelemetry). Python locks a regular
            # package's __path__ to one directory, so neither .pth nor a
            # per-entry symlink can merge it — collect the roots for the
            # physical merge in pass 2a, and record every all-namespace
            # claimant sp.
            tl_prefix = tl + "/"
            tl_conflicted_roots = {}
            for sp_a in distinct_sp.keys():
                ns_claimant_sps[sp_a] = True
                w_a = wheel_by_sp[sp_a]
                for root in w_a.regular_roots:
                    if not root.startswith(tl_prefix):
                        continue
                    for sp_b in distinct_sp.keys():
                        if sp_b == sp_a:
                            continue
                        w_b = wheel_by_sp[sp_b]
                        if (root in w_b.namespace_dirs or
                            root in w_b.regular_roots):
                            tl_conflicted_roots[root] = True

            unique_claimants = distinct_sp.values()

            native_candidates = [
                root
                for root in tl_conflicted_roots
                if any([root in wheel_by_sp[c.site_packages].native_roots for c in unique_claimants])
            ]

            # A native root owns every overlapping descendant. If a pure
            # conflicted root contains a native candidate, promote the outer
            # root too: merging the outer tree would still relocate the
            # native descendant, and declaring both paths would collide.
            native_conflicted_roots = _shallowest([
                root
                for root in tl_conflicted_roots
                if _covers(root, native_candidates)
            ])

            for root in tl_conflicted_roots:
                if not _under(root, native_conflicted_roots):
                    conflicted_roots[root] = True

            # Regular-span conflict: PySiteMerge owns mergeable roots; native
            # roots keep a later regular-claimant direct projection instead.
            # A distinct losing native claimant stays on .pth so a regular
            # package that extends __path__ can still see its graft. A losing
            # prior claimant with duplicate declared metadata is covered
            # instead: its fallback would expose an unsuppressible duplicate
            # metadata entry. The selected duplicate claimant still keeps
            # fallback when needed. Sibling namespace entries still get
            # concrete per-entry symlinks. Metadata-unknown wheels also need
            # .pth.
            if tl_conflicted_roots:
                claimants_with_entries = [c for c in unique_claimants if c.ns_entries]
                for c in unique_claimants:
                    if not c.ns_entries:
                        skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True

                native_winner_by_root = {}
                for root in native_conflicted_roots:
                    # A namespace-only projection cannot own runtime imports
                    # while a regular claimant exists: Python binds the
                    # regular package first and hides the namespace graft.
                    # Every conflicted root has a regular claimant by
                    # construction above.
                    regulars = [
                        c
                        for c in unique_claimants
                        if root in wheel_by_sp[c.site_packages].regular_roots
                    ]
                    if not regulars:
                        fail("{}: native conflicted root {} has no regular claimant.".format(ctx.label, root))
                    winner_sp = regulars[-1].site_packages
                    top_level_to_site_pkgs[root] = winner_sp
                    native_winner_by_root[root] = winner_sp

                for c in unique_claimants:
                    w = wheel_by_sp[c.site_packages]
                    for root, winner_sp in native_winner_by_root.items():
                        contributes = (
                            root in w.regular_roots or
                            root in w.namespace_dirs or
                            _covers(root, c.ns_entries)
                        )
                        if contributes:
                            if (c.site_packages != winner_sp and
                                c.site_packages not in duplicate_metadata_loser_sps):
                                skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True

                if claimants_with_entries:
                    entry_owner = _own_entries(claimants_with_entries, tl, tl_conflicted_roots)
                    for entry, c in entry_owner.items():
                        top_level_to_site_pkgs[entry] = c.site_packages
                    for c in claimants_with_entries:
                        if tl not in skipped_per_wheel.get(c.site_packages, {}):
                            covered_per_wheel.setdefault(c.site_packages, {})[tl] = True
                continue

            # Pure PEP 420 namespace (no regular package spanning wheels).
            # Entry metadata is optional (a hand-written py_unpacked_wheel
            # may omit it). Merge the claimants that HAVE entries
            # concretely, and route the entryless ones to the .pth
            # fallback: a concrete `site-packages/<tl>/` directory (no
            # `__init__.py`) and a .pth/addsitedir portion both contribute
            # to the same PEP 420 namespace at runtime, so the well-formed
            # wheels stay visible to static tools (mypy, pyright) while the
            # entryless wheel still resolves at import time. Only when NO
            # claimant has entries do we keep the historical .pth-only
            # fallback for the whole group.
            claimants_with_entries = [c for c in unique_claimants if c.ns_entries]
            for c in unique_claimants:
                if not c.ns_entries:
                    skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True
            if not claimants_with_entries:
                continue

            entry_owner = _own_entries(claimants_with_entries, tl, [])

            # A nested-namespace mismatch (wheel A ships
            # `google/cloud/__init__.py` while wheel B treats
            # `google/cloud` as a namespace and ships
            # `google/cloud/bigquery`) yields an entry that is a
            # path-prefix of another — two declared outputs at
            # conflicting paths. Keep the shallower entry (its symlink
            # subsumes the deeper region) and leave the deeper wheel on
            # the .pth path.
            #
            # KNOWN LIMITATION: this is a heuristic, not a full merge.
            # When the shallower entry is a REGULAR package (A's
            # `google/cloud/__init__.py`), `google.cloud` is not a
            # namespace at runtime, so B's `.pth`-routed
            # `google/cloud/bigquery` is shadowed and won't import — a flat
            # `pip install` would instead overlay both into one
            # `google/cloud/` directory. Correctly handling that needs a
            # recursive merge at the conflict depth (symlink A's
            # `__init__.py` + members AND B's subpackages into a concrete
            # `google/cloud/`), which in turn needs per-member metadata we
            # don't currently emit. We surface the conflict via
            # `package_collisions` rather than silently mis-merging. No
            # wheel set in our fixtures hits this (every google-* wheel
            # treats `google/cloud` as a namespace); it's defensive.
            for entry in entry_owner.keys():
                segments = entry.split("/")
                for depth in range(2, len(segments)):
                    shallower = entry_owner.get("/".join(segments[:depth]))
                    if shallower == None:
                        continue
                    loser = entry_owner.pop(entry)
                    if shallower.site_packages != loser.site_packages:
                        _complain("namespace entry", entry, shallower.site_packages, loser.site_packages)
                        skipped_per_wheel.setdefault(loser.site_packages, {})[tl] = True
                    break

            for entry, c in entry_owner.items():
                top_level_to_site_pkgs[entry] = c.site_packages

            # Entries bearing claimants that kept every one of their
            # entries are fully represented by the merged directory; record
            # per-wheel coverage so pass 3 can drop them from the .pth
            # fallback. Entryless claimants stay in skipped_per_wheel
            # (routed to .pth above) and are intentionally excluded.
            for c in claimants_with_entries:
                if tl not in skipped_per_wheel.get(c.site_packages, {}):
                    covered_per_wheel.setdefault(c.site_packages, {})[tl] = True
            continue

        _complain_chain("top-level", tl, distinct_sp.keys())
        distinct_claimants = distinct_sp.values()

        # Mixed regular/namespace claims are necessarily directories. For
        # ordinary collisions, RECORD-derived claims distinguish directories
        # that can merge from single-file modules that must keep precedence.
        all_directories = any_namespace or all([c.is_dir for c in distinct_claimants])
        has_native_root = any([c.is_native for c in distinct_claimants])

        if all_directories:
            if has_native_root:
                # Native libraries may resolve sibling assets from their
                # physical origin. Keep the later regular claimant as a
                # direct wheel-relative projection instead of copying it
                # into a merge tree. Distinct losing distributions stay on
                # fallback for __path__-extending regular packages; duplicate
                # metadata losers are suppressed so their metadata cannot
                # remain visible from another sys.path entry.
                winner = [c for c in distinct_claimants if not c.is_ns][-1]
                top_level_to_site_pkgs[tl] = winner.site_packages
                for c in distinct_claimants:
                    if (c.site_packages == winner.site_packages or
                        c.site_packages in duplicate_metadata_loser_sps):
                        covered_per_wheel.setdefault(c.site_packages, {})[tl] = True
                    else:
                        skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True
            else:
                for c in distinct_claimants:
                    covered_per_wheel.setdefault(c.site_packages, {})[tl] = True
                merge_groups.append(struct(
                    root = tl,
                    site_packages_list = [c.site_packages for c in distinct_claimants],
                ))
            continue

        winner = distinct_claimants[-1]
        for c in distinct_claimants:
            if c.site_packages != winner.site_packages:
                skipped_per_wheel.setdefault(c.site_packages, {})[tl] = True
        top_level_to_site_pkgs[tl] = winner.site_packages

    # Pass 2a: fold conflicted roots into merge groups. A conflicted root
    # nested inside another conflicted root is covered by merging the
    # outer one. For each root, the contributors are every
    # namespace-claimant wheel that has the root in its skeleton (content
    # below it) or as its own regular root, in wheel traversal order.
    ordered_sps = _distinct_claimants([w.site_packages_rfpath for w in wheels])
    for root in _shallowest(conflicted_roots.keys()):
        group_sps = [
            sp
            for sp in ordered_sps
            if sp in ns_claimant_sps and
               (root in wheel_by_sp[sp].regular_roots or
                root in wheel_by_sp[sp].namespace_dirs)
        ]
        if len(group_sps) >= 2:
            merge_groups.append(struct(
                root = root,
                site_packages_list = group_sps,
            ))

    # Pass 2b: console scripts.
    console_scripts_map = {}
    for name, claimants in cs_claimants.items():
        distinct_sp = _distinct_by_sp(claimants)
        _complain_chain("console script", name, distinct_sp.keys())
        winner = distinct_sp.values()[-1]
        console_scripts_map[name] = struct(module = winner.module, func = winner.func)

    # Pass 3: wheels fully covered by direct (or complete per-entry
    # namespace) symlinks.
    fully_covered = {}
    for w in wheels:
        if not w.top_levels:
            continue
        sp = w.site_packages_rfpath
        skipped = skipped_per_wheel.get(sp, {})
        covered_roots = covered_per_wheel.get(sp, {})
        covered = True

        # tl_claims carries exactly the non-metadata top-levels.
        for tl, _ in w.tl_claims:
            if tl in skipped or (
                top_level_to_site_pkgs.get(tl) != sp and tl not in covered_roots
            ):
                covered = False
                break
        if covered:
            fully_covered[sp] = True

    # Metadata discovery scans every sys.path entry. Resolve duplicate declared
    # metadata entries with the existing collision precedence, but first reject
    # a losing claimant that remains on whole-wheel fallback because downgrading
    # the collision cannot suppress that copy. Project the winner only when its
    # fallback is gone. Wheels without declared layout metadata remain on the
    # existing whole-wheel fallback and cannot be classified here.
    for tl, claimants in metadata_claimants.items():
        distinct = _distinct_claimants(claimants)
        winner = distinct[-1]

        # The explicit fail must precede the _complain calls so it wins
        # over _complain's generic error under package_collisions = "error".
        for site_packages in distinct[:-1]:
            if site_packages not in fully_covered:
                fail(("{}: distribution metadata entry `{}` selects {}, but " +
                      "losing claimant {} remains on whole-wheel fallback.").format(
                    ctx.label,
                    tl,
                    winner,
                    site_packages,
                ))
        _complain_chain("distribution metadata entry", tl, distinct)
        if winner in fully_covered:
            top_level_to_site_pkgs[tl] = winner

    return top_level_to_site_pkgs, fully_covered, console_scripts_map, merge_groups
