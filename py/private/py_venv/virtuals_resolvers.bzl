"""Wheel collision and namespace merge resolution for venv site-packages.

Walks PyWheelsInfo.wheels and produces merge plans that the venv
assembler turns into per-entry symlinks, physical merges, and
console-script wrappers.

Pure Starlark — no external loads, operates solely on wheel struct
fields and ``ctx.label``.
"""

def _is_within(path, root):
    """True when *path* equals *root* or is a direct descendant."""
    return path == root or path.startswith(root + "/")

def _within_any(path, roots):
    """True when *path* sits at or below any entry in *roots*."""
    for root in roots:
        if path == root or path.startswith(root + "/"):
            return True
    return False

def _contains_any(root, paths):
    """True when *root* equals or contains any entry in *paths*."""
    for p in paths:
        if p == root or p.startswith(root + "/"):
            return True
    return False

def _shallowest(roots):
    """Minimal cover of *roots*: drop any root nested below another.

    Lexicographic sort puts ancestors before descendants, so a single
    left-to-right pass suffices.
    """
    out = []
    for root in sorted(roots):
        if not _within_any(root, out):
            out.append(root)
    return out

def _distinct_ordered(keys):
    """Dedup *keys* preserving first-seen order.

    Collision precedence is "last distinct entry wins": the final
    element is the winner, everything before it is a loser.
    """
    return {k: True for k in keys}.keys()

def _last_per_sp(claimants):
    """Last claim struct per distinct ``site_packages``, in first-claim order.

    Starlark dicts preserve insertion order, and overwriting a key keeps
    its original position.  ``.keys()`` is therefore the distinct-claimant
    precedence chain (last wins) and ``.values()`` the matching structs.
    """
    return {c.site_packages: c for c in claimants}

def _new_state():
    """Mutable accumulator for collision-resolution passes."""
    return struct(
        top_level_to_site_pkgs = {},
        skipped_per_wheel = {},
        covered_per_wheel = {},
        merge_groups = [],
        conflicted_roots = {},
        ns_claimant_sps = {},
    )

def _skip(state, sp, tl):
    """Route ``(sp, tl)`` to the ``.pth`` fallback."""
    state.skipped_per_wheel.setdefault(sp, {})[tl] = True

def _cover(state, sp, tl):
    """Mark ``(sp, tl)`` as projected, merged, or suppressed."""
    state.covered_per_wheel.setdefault(sp, {})[tl] = True

def _cover_if_clean(state, sp, tl):
    """Cover ``(sp, tl)`` only when it was not routed to ``.pth``."""
    if tl not in state.skipped_per_wheel.get(sp, {}):
        _cover(state, sp, tl)

def _skip_entryless_and_split(unique_claimants, state, tl):
    """Route entryless claimants to ``.pth`` and return the rest.

    Returns the sublist of claimants that carry ``ns_entries``.
    """
    with_entries = []
    for c in unique_claimants:
        if c.ns_entries:
            with_entries.append(c)
        else:
            _skip(state, c.site_packages, tl)
    return with_entries

def _cover_all_clean(claimants, state, tl):
    """Cover every claimant that was not routed to ``.pth``."""
    for c in claimants:
        _cover_if_clean(state, c.site_packages, tl)

def _make_complainer(ctx, package_collisions):
    """Build a closure that reports collisions per *package_collisions* policy."""

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

    return _complain

def _complain_chain(complain, what, name, distinct):
    """Report once per takeover along a distinct-claimant chain."""
    for i in range(1, len(distinct)):
        complain(what, name, distinct[i - 1], distinct[i])

def _resolve_entry_owners(claimants, tl, exclude_roots, state, complain):
    """Assign each namespace entry to the last distinct wheel claiming it.

    An earlier wheel shipping the same entry is a genuine collision
    (same subpackage twice) — the perdedor is reported and routed to
    ``.pth``.  Entries under *exclude_roots* are owned by a direct native
    projection or physical merge and are skipped here.
    """
    entry_owner = {}
    for c in claimants:
        for entry in c.ns_entries:
            if _within_any(entry, exclude_roots):
                continue
            prior = entry_owner.get(entry)
            if prior == None:
                entry_owner[entry] = c
            elif prior.site_packages != c.site_packages:
                complain("namespace entry", entry, prior.site_packages, c.site_packages)
                _skip(state, prior.site_packages, tl)
                entry_owner[entry] = c
    return entry_owner

def _dedupe_prefix_conflicts(entry_owner, tl, state, complain):
    """Resolve entries whose path is a prefix of another.

    A nested-namespace mismatch (wheel A ships ``google/cloud`` while
    wheel B ships ``google/cloud/bigquery``) produces two declared
    outputs at conflicting paths.  The shallower entry's symlink
    subsumes the deeper region; the deeper wheel is routed to ``.pth``.

    Known limitation: when the shallower entry is a regular package
    (has ``__init__.py``), Python shadows the deeper ``.pth`` entry at
    runtime.  A correct fix needs recursive per-member metadata that is
    not currently emitted.  The conflict is surfaced via
    ``package_collisions`` rather than silently mis-merging.
    """
    for entry in list(entry_owner.keys()):
        segments = entry.split("/")
        for depth in range(2, len(segments)):
            shallower = entry_owner.get("/".join(segments[:depth]))
            if shallower == None:
                continue
            loser = entry_owner.pop(entry)
            if shallower.site_packages != loser.site_packages:
                complain("namespace entry", entry, shallower.site_packages, loser.site_packages)
                _skip(state, loser.site_packages, tl)
            break

def _build_wheel_lookup_sets(wheel_by_sp, sps):
    """Pre-compute O(1) membership dicts for per-wheel root tuples.

    ``namespace_dirs``, ``regular_roots``, and ``native_roots`` are
    tuples in the wheel record; converting them to dict keys once
    avoids O(n) linear scans inside tight N x N loops.
    """
    ns_dirs = {}
    regular_roots = {}
    native_roots = {}
    for sp in sps:
        w = wheel_by_sp[sp]
        ns_dirs[sp] = {d: True for d in getattr(w, "namespace_dirs", ())}
        regular_roots[sp] = {r: True for r in getattr(w, "regular_roots", ())}
        native_roots[sp] = {r: True for r in getattr(w, "native_roots", ())}
    return ns_dirs, regular_roots, native_roots

def _scan_namespace_conflicts(tl, distinct_sps, wheel_by_sp, state):
    """Detect regular-package roots that span multiple namespace wheels.

    Cross-references each wheel's ``regular_roots`` against every other
    claimant's ``namespace_dirs`` and ``regular_roots``.  A match means
    a regular package (with ``__init__.py``) lives in one wheel while
    another wheel installs files below it — Python locks
    ``__path__`` to the first directory found, so neither ``.pth`` nor
    per-entry symlinks can merge it.

    Returns ``(conflicted_roots_dict, native_candidate_roots_dict)`` and
    records every namespace claimant in ``state.ns_claimant_sps``.
    """
    sps = list(distinct_sps)
    ns_dirs, regular_roots, _native = _build_wheel_lookup_sets(wheel_by_sp, sps)
    tl_prefix = tl + "/"
    conflicted = {}
    for sp_a in sps:
        state.ns_claimant_sps[sp_a] = True
        w_a = wheel_by_sp[sp_a]
        for root in getattr(w_a, "regular_roots", ()):
            if not root.startswith(tl_prefix):
                continue
            for sp_b in sps:
                if sp_b == sp_a:
                    continue
                if root in ns_dirs[sp_b] or root in regular_roots[sp_b]:
                    conflicted[root] = True
    return conflicted

def _classify_conflicted_roots(conflicted, unique_claimants, wheel_by_sp):
    """Split conflicted roots into native (direct projection) and mergeable.

    A native root carries ``.so``/``.dylib`` files and cannot be copied
    into a merge tree without changing the library's physical origin.
    Roots that cover a native candidate are promoted to avoid declaring
    both an ancestor and descendant as outputs.
    """
    sps = [c.site_packages for c in unique_claimants]
    _, _, native_roots = _build_wheel_lookup_sets(wheel_by_sp, sps)
    native_candidates = [
        root
        for root in conflicted
        if any([root in native_roots[c.site_packages] for c in unique_claimants])
    ]
    native_conflicted = _shallowest([
        root
        for root in conflicted
        if _contains_any(root, native_candidates)
    ])
    mergeable = {
        root: True
        for root in conflicted
        if not _within_any(root, native_conflicted)
    }
    return native_conflicted, mergeable

def _resolve_native_span(
        native_roots,
        tl_conflicted_roots,
        unique_claimants,
        wheel_by_sp,
        tl,
        state,
        complain,
        ctx,
        duplicate_metadata_loser_sps):
    """Resolve native conflicted roots via direct wheel projection.

    A namespace-only projection cannot own runtime imports while a
    regular claimant exists: Python binds the regular package first and
    hides the namespace graft.  The last regular claimant per native
    root wins as a direct symlink.  Losing wheels stay on ``.pth``
    unless they carry duplicate metadata (their fallback would expose
    an unsuppressible duplicate entry).
    """
    _, regular_roots, _ = _build_wheel_lookup_sets(
        wheel_by_sp,
        [c.site_packages for c in unique_claimants],
    )
    native_winner_by_root = {}
    for root in native_roots:
        regulars = [
            c
            for c in unique_claimants
            if root in regular_roots[c.site_packages]
        ]
        if not regulars:
            fail("{}: native conflicted root {} has no regular claimant.".format(ctx.label, root))
        winner_sp = regulars[-1].site_packages
        state.top_level_to_site_pkgs[root] = winner_sp
        native_winner_by_root[root] = winner_sp

    for c in unique_claimants:
        w = wheel_by_sp[c.site_packages]
        ns_dirs = {d: True for d in getattr(w, "namespace_dirs", ())}
        regs = {r: True for r in getattr(w, "regular_roots", ())}
        for root, winner_sp in native_winner_by_root.items():
            if (root in regs or root in ns_dirs or _contains_any(root, c.ns_entries)):
                if (c.site_packages != winner_sp and
                    c.site_packages not in duplicate_metadata_loser_sps):
                    _skip(state, c.site_packages, tl)

    with_entries = _skip_entryless_and_split(unique_claimants, state, tl)
    if with_entries:
        entry_owner = _resolve_entry_owners(with_entries, tl, tl_conflicted_roots, state, complain)
        for entry, c in entry_owner.items():
            state.top_level_to_site_pkgs[entry] = c.site_packages
        _cover_all_clean(with_entries, state, tl)

def _resolve_pure_namespace(unique_claimants, tl, state, complain):
    """Resolve a PEP 420 namespace top-level with no regular-span conflict.

    Entry metadata is optional (a hand-written ``py_unpacked_wheel``
    may omit it).  Claimants with entries get concrete per-entry
    symlinks; entryless claimants are routed to ``.pth``.  Only when no
    claimant has entries does the whole group stay on ``.pth``.
    """
    with_entries = _skip_entryless_and_split(unique_claimants, state, tl)
    if not with_entries:
        return
    entry_owner = _resolve_entry_owners(with_entries, tl, [], state, complain)
    _dedupe_prefix_conflicts(entry_owner, tl, state, complain)
    for entry, c in entry_owner.items():
        state.top_level_to_site_pkgs[entry] = c.site_packages
    _cover_all_clean(with_entries, state, tl)

def _resolve_directory_collision(
        tl,
        distinct_claimants,
        any_namespace,
        state,
        duplicate_metadata_loser_sps):
    """Resolve a collision where all claimants are directories.

    Without native roots, a physical merge (``PySiteMerge`` action)
    overlays every wheel's subtree — the layout a flat ``pip install``
    produces.  With native roots, the last regular claimant wins as a
    direct projection; losers stay on ``.pth`` unless their metadata is
    duplicated (unsuppressible from another sys.path entry).
    """
    all_covered = True
    for c in distinct_claimants:
        if c.is_native:
            all_covered = False
            break

    if not all_covered:
        winner = [c for c in distinct_claimants if not c.is_ns][-1]
        state.top_level_to_site_pkgs[tl] = winner.site_packages
        for c in distinct_claimants:
            if (c.site_packages == winner.site_packages or
                c.site_packages in duplicate_metadata_loser_sps):
                _cover(state, c.site_packages, tl)
            else:
                _skip(state, c.site_packages, tl)
    else:
        for c in distinct_claimants:
            _cover(state, c.site_packages, tl)
        state.merge_groups.append(struct(
            root = tl,
            site_packages_list = [c.site_packages for c in distinct_claimants],
        ))

def _resolve_top_level(
        tl,
        claimants,
        wheel_by_sp,
        state,
        complain,
        ctx,
        duplicate_metadata_loser_sps):
    """Resolve one top-level entry across all claiming wheels."""
    distinct_sp = _last_per_sp(claimants)
    if len(distinct_sp) == 1:
        state.top_level_to_site_pkgs[tl] = claimants[0].site_packages
        return

    all_namespace = all([c.is_ns for c in claimants])
    any_namespace = any([c.is_ns for c in claimants])

    if all_namespace:
        unique_claimants = distinct_sp.values()
        tl_conflicted_roots = _scan_namespace_conflicts(tl, distinct_sp.keys(), wheel_by_sp, state)

        if tl_conflicted_roots:
            native_conflicted, mergeable = _classify_conflicted_roots(
                tl_conflicted_roots,
                unique_claimants,
                wheel_by_sp,
            )
            for root in mergeable:
                state.conflicted_roots[root] = True

            _resolve_native_span(
                native_conflicted,
                tl_conflicted_roots,
                unique_claimants,
                wheel_by_sp,
                tl,
                state,
                complain,
                ctx,
                duplicate_metadata_loser_sps,
            )
        else:
            _resolve_pure_namespace(unique_claimants, tl, state, complain)
        return

    _complain_chain(complain, "top-level", tl, distinct_sp.keys())
    distinct_claimants = distinct_sp.values()
    all_directories = any_namespace or all([c.is_dir for c in distinct_claimants])

    if all_directories:
        _resolve_directory_collision(
            tl,
            distinct_claimants,
            any_namespace,
            state,
            duplicate_metadata_loser_sps,
        )
        return

    winner = distinct_claimants[-1]
    for c in distinct_claimants:
        if c.site_packages != winner.site_packages:
            _skip(state, c.site_packages, tl)
    state.top_level_to_site_pkgs[tl] = winner.site_packages

def _fold_merge_groups(wheels, wheel_by_sp, state):
    """Fold conflicted roots into ``PySiteMerge`` merge groups.

    A conflicted root nested inside another is covered by the outer
    merge.  Contributors are namespace-claimant wheels whose skeleton or
    regular roots include the path, in wheel traversal order.
    """
    ordered_sps = _distinct_ordered([w.site_packages_rfpath for w in wheels])
    for root in _shallowest(state.conflicted_roots.keys()):
        group_sps = [
            sp
            for sp in ordered_sps
            if sp in state.ns_claimant_sps and (
                root in {d: True for d in getattr(wheel_by_sp[sp], "namespace_dirs", ())} or
                root in {r: True for r in getattr(wheel_by_sp[sp], "regular_roots", ())}
            )
        ]
        if len(group_sps) >= 2:
            state.merge_groups.append(struct(
                root = root,
                site_packages_list = group_sps,
            ))

def _resolve_console_scripts(cs_claimants, complain):
    """Resolve console-script name collisions (last distinct wheel wins)."""
    console_scripts_map = {}
    for name, claimants in cs_claimants.items():
        distinct_sp = _last_per_sp(claimants)
        _complain_chain(complain, "console script", name, distinct_sp.keys())
        winner = distinct_sp.values()[-1]
        console_scripts_map[name] = struct(module = winner.module, func = winner.func)
    return console_scripts_map

def _compute_fully_covered(wheels, state):
    """Determine which wheels have every top-level projected or merged.

    Such wheels are safe to drop from the ``.pth`` fallback entirely.
    Wheels without declared layout metadata (empty ``top_levels``)
    cannot be classified and are excluded.
    """
    fully_covered = {}
    for w in wheels:
        if not w.top_levels:
            continue
        sp = w.site_packages_rfpath
        skipped = state.skipped_per_wheel.get(sp, {})
        covered_roots = state.covered_per_wheel.get(sp, {})
        covered = True
        for tl, _ in w.tl_claims:
            if tl in skipped or (
                state.top_level_to_site_pkgs.get(tl) != sp and tl not in covered_roots
            ):
                covered = False
                break
        if covered:
            fully_covered[sp] = True
    return fully_covered

def _resolve_metadata_collisions(metadata_claimants, state, fully_covered, complain, ctx):
    """Resolve duplicate ``.dist-info`` / ``.egg-info`` entries.

    Python's metadata discovery scans every ``sys.path`` entry, so a
    losing wheel remaining on ``.pth`` fallback would expose an
    unsuppressible duplicate.  The explicit ``fail`` precedes
    ``_complain_chain`` so the specific error wins under
    ``package_collisions = "error"``.  The winner is projected only
    when fully covered (fallback gone).
    """
    for tl, claimants in metadata_claimants.items():
        distinct = _distinct_ordered(claimants)
        winner = distinct[-1]
        for site_packages in distinct[:-1]:
            if site_packages not in fully_covered:
                fail(("{}: distribution metadata entry `{}` selects {}, but " +
                      "losing claimant {} remains on whole-wheel fallback.").format(
                    ctx.label,
                    tl,
                    winner,
                    site_packages,
                ))
        _complain_chain(complain, "distribution metadata entry", tl, distinct)
        if winner in fully_covered:
            state.top_level_to_site_pkgs[tl] = winner

def resolve_wheel_collisions(ctx, wheels, package_collisions):
    """Walk ``PyWheelsInfo.wheels`` and produce merge plans for site-packages + bin/.

    Three kinds of collision are checked:

    * **Top-level in site-packages.**  Multiple wheels claiming the same
      top-level name.  When all flag the name as a PEP 420 namespace
      package, the collision is benign and the namespace is merged
      concretely with per-entry symlinks.  When a regular package spans
      wheels (e.g. azure-core + azure-core-tracing-opentelemetry), the
      conflicted subtrees are physically merged via ``PySiteMerge``.
      Native roots stay on direct wheel projections.  Otherwise the
      ``package_collisions`` policy decides.

    * **Declared distribution metadata.**  Resolved with the same
      last-distinct-wins precedence, but a losing claimant remaining on
      whole-wheel fallback is rejected because metadata discovery scans
      every ``sys.path`` entry.

    * **Console-script names.**  Last distinct wheel wins; no namespace
      equivalent.

    Returns:
      (top_level_to_site_pkgs, fully_covered, console_scripts_map, merge_groups)
    """
    complain = _make_complainer(ctx, package_collisions)
    state = _new_state()

    tl_claimants = {}
    metadata_claimants = {}
    cs_claimants = {}
    wheel_by_sp = {}
    for w in wheels:
        wheel_by_sp[w.site_packages_rfpath] = w
        for tl in w.metadata_top_levels:
            metadata_claimants.setdefault(tl, []).append(w.site_packages_rfpath)
        for tl, claim in w.tl_claims:
            tl_claimants.setdefault(tl, []).append(claim)
        for name, claim in w.cs_claims:
            cs_claimants.setdefault(name, []).append(claim)

    duplicate_metadata_loser_sps = {
        loser: True
        for claimants in metadata_claimants.values()
        for loser in _distinct_ordered(claimants)[:-1]
    }

    for tl, claimants in tl_claimants.items():
        _resolve_top_level(
            tl,
            claimants,
            wheel_by_sp,
            state,
            complain,
            ctx,
            duplicate_metadata_loser_sps,
        )

    _fold_merge_groups(wheels, wheel_by_sp, state)
    console_scripts_map = _resolve_console_scripts(cs_claimants, complain)
    fully_covered = _compute_fully_covered(wheels, state)
    _resolve_metadata_collisions(metadata_claimants, state, fully_covered, complain, ctx)

    return (
        state.top_level_to_site_pkgs,
        fully_covered,
        console_scripts_map,
        state.merge_groups,
    )
