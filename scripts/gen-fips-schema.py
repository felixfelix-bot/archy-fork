#!/usr/bin/env python3
"""Extract the valid `fips.yaml` key paths from upstream FIPS source.

The upstream example config (`packaging/common/fips.yaml`) documents only a
fraction of the schema — `node.retry.*` and `node.rate_limit.*`, which
archipelago sets, appear nowhere in it. Asserting our generated config against
the example text alone therefore produces false failures.

The authority is the source: `#[derive(Deserialize)]` structs and their
`pub <name>: <Type>` fields. This script resolves the field tree from the
top-level `Config` down through nested struct definitions and prints one dotted
path per line, so a test can assert set membership.

Usage:
    ./scripts/gen-fips-schema.py --tag v0.5.3            # print to stdout
    ./scripts/gen-fips-schema.py --tag v0.5.3 --write    # write the fixture
    ./scripts/gen-fips-schema.py --tag v0.5.3 --repo ~/repos/fips-upstream

Exit codes: 0 ok, 1 extraction problem (empty/implausible result).
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# Files that hold config structs, and the root struct to walk from.
SOURCE_FILES = [
    "src/config/mod.rs",
    "src/config/node.rs",
    "src/config/transport.rs",
    "src/config/peer.rs",
    "src/config/gateway.rs",
    "src/upper/config.rs",
    "src/mdns/mod.rs",
]
ROOT_STRUCT = "Config"

# `pub struct Name {` … or `pub struct Name<T> {`
# MULTILINE is required: this is run over whole files, not single lines.
STRUCT_RE = re.compile(
    r"^\s*(?:pub(?:\(crate\))?\s+)?struct\s+(\w+)\s*(?:<[^>]*>)?\s*\{", re.MULTILINE
)
# `pub name: Type,` — also `pub(crate) name: Type,`
FIELD_RE = re.compile(r"^\s*(?:pub(?:\(crate\))?\s+)?(\w+)\s*:\s*(.+?),\s*$")
# Wrappers that do not add a path segment.
WRAPPER_RE = re.compile(r"^(?:Option|Vec|Box|Arc)\s*<(.+)>$")
# `TransportInstances<UdpConfig>` serializes as the instance config itself.
INSTANCES_RE = re.compile(r"^TransportInstances\s*<(.+)>$")


def git_show(repo: Path, tag: str, path: str) -> str:
    out = subprocess.run(
        ["git", "-C", str(repo), "show", f"{tag}:{path}"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise SystemExit(f"FAIL: git show {tag}:{path} — {out.stderr.strip()}")
    return out.stdout


def strip_rust_noise(src: str) -> str:
    """Remove line comments and block comments.

    Brace counting is only sound once `{`/`}` inside comments are gone —
    otherwise a struct earlier in the file swallows every later definition and
    the root struct is never found.

    Deliberately does NOT touch string/char literals: a naive literal scanner
    mis-handles lifetimes, raw strings and multi-byte boundaries, and ate ~half
    of `src/config/mod.rs` when tried (2026-10-23). Instead the caller asserts
    the result is brace-balanced, so a brace inside a string literal fails
    loudly rather than silently truncating the schema.
    """
    out: list[str] = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and nxt == "*":
            depth = 1
            i += 2
            while i < n and depth:
                if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
                    depth += 1
                    i += 2
                elif src[i] == "*" and i + 1 < n and src[i + 1] == "/":
                    depth -= 1
                    i += 2
                else:
                    if src[i] == "\n":
                        out.append("\n")
                    i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def parse_structs(sources: dict[str, str]) -> dict[str, list[tuple[str, str]]]:
    """Map struct name -> [(field_name, raw_type)].

    Brace-matched from each `struct Name {` to its closing brace, so a nested
    struct body cannot bleed into the next definition.
    """
    structs: dict[str, list[tuple[str, str]]] = {}
    for path, src in sources.items():
        clean = strip_rust_noise(src)
        if clean.count("{") != clean.count("}"):
            raise SystemExit(
                f"FAIL: {path} is brace-unbalanced after comment stripping "
                f"({clean.count('{')} vs {clean.count('}')}) — a brace inside a "
                f"string literal breaks this parser; fix the parser before trusting it"
            )
        for m in STRUCT_RE.finditer(clean):
            name = m.group(1)
            start = clean.find("{", m.end() - 1)
            if start == -1:
                continue
            depth = 0
            end = start
            for k in range(start, len(clean)):
                if clean[k] == "{":
                    depth += 1
                elif clean[k] == "}":
                    depth -= 1
                    if depth == 0:
                        end = k
                        break
            body = clean[start + 1 : end]
            # Only top-level fields of THIS struct (nested braces belong to
            # inline types, not to this struct's field list).
            fields: list[tuple[str, str]] = []
            depth = 0
            for line in body.splitlines():
                if depth == 0:
                    fm = FIELD_RE.match(line)
                    if fm and not fm.group(1).startswith("#"):
                        fields.append((fm.group(1), fm.group(2).strip()))
                depth += line.count("{") - line.count("}")
            structs.setdefault(name, fields)
    return structs


def resolve_struct(ty: str, structs: dict[str, list[tuple[str, str]]]) -> str | None:
    """Return the struct name a field's type denotes, if it is a known struct."""
    ty = ty.strip()
    while True:
        m = INSTANCES_RE.match(ty) or WRAPPER_RE.match(ty)
        if not m:
            break
        ty = m.group(1).strip()
    # Strip module paths: `crate::mdns::LanRendezvousConfig` -> `LanRendezvousConfig`
    ty = ty.rsplit("::", 1)[-1]
    ty = ty.split("<", 1)[0].strip()
    return ty if ty in structs else None


def walk(
    struct: str,
    structs: dict[str, list[tuple[str, str]]],
    prefix: str,
    out: set[str],
    seen: frozenset[str] = frozenset(),
) -> None:
    if struct in seen:
        return
    for name, ty in structs.get(struct, []):
        path = f"{prefix}.{name}" if prefix else name
        out.add(path)
        nested = resolve_struct(ty, structs)
        if nested:
            walk(nested, structs, path, out, seen | {struct})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--repo", default=str(Path.home() / "repos" / "fips-upstream"))
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--out-dir", default=None)
    args = ap.parse_args()

    repo = Path(args.repo).expanduser()
    if not (repo / ".git").exists():
        raise SystemExit(f"FAIL: no git repo at {repo}")

    sources: dict[str, str] = {}
    for path in SOURCE_FILES:
        try:
            sources[path] = git_show(repo, args.tag, path)
        except SystemExit as exc:
            print(f"note: {exc}", file=sys.stderr)

    structs = parse_structs(sources)
    if ROOT_STRUCT not in structs:
        raise SystemExit(f"FAIL: root struct `{ROOT_STRUCT}` not found in upstream source")

    paths: set[str] = set()
    walk(ROOT_STRUCT, structs, "", paths)

    # The root struct's own name is not a key.
    paths.discard(ROOT_STRUCT)
    # Sanity floors: a parser regression must not silently pass a truncated set.
    if len(paths) < 50:
        raise SystemExit(f"FAIL: only {len(paths)} paths extracted — parser likely broke")
    for required in (
        "node.retry.base_interval_secs",
        "node.rate_limit.handshake_resend_backoff",
        "node.lookup.backoff_base_secs",
        "node.rendezvous.lan.enabled",
        "tun.name",
        "dns.bind_addr",
        "transports.udp",
        "peers",
    ):
        if required not in paths:
            raise SystemExit(f"FAIL: expected path `{required}` missing from extraction")

    body = "\n".join(sorted(paths)) + "\n"

    if args.write:
        out_dir = Path(args.out_dir) if args.out_dir else Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "fips"
        out_dir.mkdir(parents=True, exist_ok=True)
        dest = out_dir / f"fips-{args.tag}-schema.txt"
        dest.write_text(
            f"# Valid fips.yaml key paths at upstream {args.tag}.\n"
            f"# Generated by scripts/gen-fips-schema.py — do not edit by hand.\n"
            f"# Regenerate on every FIPS_VERSION bump.\n"
            + body
        )
        print(f"wrote {dest} ({len(paths)} paths)")
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
