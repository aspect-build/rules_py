"""Minimal stdlib pprof decoder for Bazel `--starlark_cpu_profile` output.

Parses the protobuf-wire pprof Profile message without third-party deps and
returns CPU time aggregated by leaf Starlark function. No protobuf library --
just varint + length-delimited wire types, packed and non-packed repeated fields.

The pprof is gzip-compressed; we fall back to raw bytes if not. If the format
changes and nothing decodes, callers get an empty dict (fail-open, no crash).
"""
from __future__ import annotations

import gzip
from collections import defaultdict
from typing import Iterator


def _read_varint(buf: bytes, i: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        byte = buf[i]
        i += 1
        result |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            return result, i
        shift += 7


def _scan(buf: bytes) -> Iterator[tuple[int, int, object]]:
    """Yield (field_number, wire_type, value) for a message's top-level fields.

    value is an int for varint (wt 0/0b), raw bytes for length-delimited (wt 2),
    or raw bytes for fixed (wt 1=64bit, wt 5=32bit).
    """
    i = 0
    n = len(buf)
    while i < n:
        tag, i = _read_varint(buf, i)
        field = tag >> 3
        wt = tag & 7
        if wt == 0:
            val, i = _read_varint(buf, i)
            yield field, wt, val
        elif wt == 2:
            ln, i = _read_varint(buf, i)
            yield field, wt, buf[i:i + ln]
            i += ln
        elif wt == 1:
            yield field, wt, buf[i:i + 8]
            i += 8
        elif wt == 5:
            yield field, wt, buf[i:i + 4]
            i += 4
        else:
            return


def _fields(buf: bytes) -> dict[int, list]:
    """Parse a message into {field_number: [values]} (wt0->int, wt2->bytes)."""
    out: dict[int, list] = defaultdict(list)
    for field, wt, val in _scan(buf):
        out[field].append(val)
    return out


def _parse_packed_or_singles(buf: bytes, target_field: int) -> list[int]:
    """Read a repeated varint field that may be packed (wt2) or unpacked (wt0)."""
    vals: list[int] = []
    for field, wt, val in _scan(buf):
        if field != target_field:
            continue
        if wt == 0:
            vals.append(val)  # type: ignore[arg-type]
        elif wt == 2:
            sub = val  # type: ignore[assignment]
            j = 0
            while j < len(sub):
                v, j = _read_varint(sub, j)
                vals.append(v)
    return vals


def _read_payload(path: str) -> bytes:
    try:
        return gzip.open(path, "rb").read()
    except OSError:
        return open(path, "rb").read()


def decode_starlark_pprof(path: str) -> dict[str, float]:
    """Return {function_name: cpu_ms} aggregated by leaf Starlark function.

    Returns {} if the profile is missing or unparseable (fail-open).
    """
    data = _read_payload(path)
    top = _fields(data)

    strings_raw = top.get(6, [])
    strings = [s.decode("utf-8", "replace") if isinstance(s, bytes) else "" for s in strings_raw]

    def s(idx: object | int) -> str:
        if isinstance(idx, int) and 0 <= idx < len(strings):
            return strings[idx]
        return "<unknown>"

    # sample_type: repeated ValueType{1:type, 2:unit} (string_table indices)
    sample_types: list[tuple[str, str]] = []
    for chunk in top.get(1, []):
        f = _fields(chunk)
        t = f.get(1, [0])
        u = f.get(2, [0])
        sample_types.append((s(t[0]), s(u[0])))

    # Pick the CPU value index and its unit->ms divisor.
    val_idx = 0
    divisor = 1000.0
    for i, (_t, unit) in enumerate(sample_types):
        if unit == "microseconds":
            val_idx, divisor = i, 1000.0
        elif unit == "nanoseconds":
            val_idx, divisor = i, 1000000.0

    # function: id -> name index
    fn_name: dict[int, int] = {}
    for chunk in top.get(5, []):
        f = _fields(chunk)
        fid = f.get(1, [0])[0]
        name_idx = f.get(2, [0])[0]
        fn_name[fid] = name_idx

    # location: id -> leaf function id (first line)
    loc_to_fn: dict[int, int] = {}
    for chunk in top.get(4, []):
        f = _fields(chunk)
        lid = f.get(1, [0])[0]
        lines = f.get(4, [])
        if lines:
            line = _fields(lines[0])
            loc_to_fn[lid] = line.get(1, [0])[0]

    totals: dict[str, float] = defaultdict(float)
    for chunk in top.get(2, []):
        loc_ids = _parse_packed_or_singles(chunk, 1)
        values = _parse_packed_or_singles(chunk, 2)
        if not loc_ids or val_idx >= len(values):
            continue
        leaf = loc_ids[0]
        fid = loc_to_fn.get(leaf)
        if fid is None:
            continue
        name_idx = fn_name.get(fid)
        totals[s(name_idx)] += values[val_idx] / divisor

    return dict(totals)


if __name__ == "__main__":
    import sys
    rows = sorted(decode_starlark_pprof(sys.argv[1]).items(), key=lambda kv: -kv[1])
    for name, ms in rows[:25]:
        print(f"{ms:9.2f} ms  {name}")
