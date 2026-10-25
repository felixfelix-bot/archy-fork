#!/usr/bin/env python3
"""Assert the image masks the packaged fips.service, so archipelago is the sole
supervisor by construction.

## Why a static assertion is the right test here

`tests/regression/fips-unit-exclusive.sh` proves the *systemd semantics* (that
Conflicts= is symmetric and designates no winner). It cannot prove what the
IMAGE ships. This does: the masking has to happen at build time, in the ISO
builder, and it is a property of the build script text.

## Why masking, and not just Conflicts=

Measured 2026-10-25 (see docs/findings-fips-unit-conflicts.md): with two units
each declaring Conflicts= on the other, **the one started second survives**.
`fips.service` hangs off `multi-user.target` with no ordering constraint against
archipelago-fips.service, so at boot systemd starts it and that start stops ours.
Conflicts= therefore only prevents *simultaneous* execution; it does not protect
the supervisor the design intends to keep.

Masking makes the packaged unit unstartable, so the invariant no longer depends
on boot ordering.

## Why `rm` + `/dev/null` symlink, not `systemctl mask`

The builder already documents this for nostr-vpn: "`systemctl mask` alone doesn't
stick because the real .service file is already in place — explicit rm +
/dev/null symlink is what sticks." `systemctl mask` in a container build also
targets the build container's runtime state, which does not survive into the
image. The symlink does.

Usage: python3 tests/regression/fips-service-masked.py
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent.parent
ISO_BUILDER = REPO / "image-recipe/_archived/build-auto-installer-iso.sh"

failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if cond:
        print(f"OK:   {msg}")
    else:
        print(f"FAIL: {msg}", file=sys.stderr)
        failures.append(msg)


def main() -> int:
    if not ISO_BUILDER.is_file():
        print(f"FAIL: ISO builder not found: {ISO_BUILDER}", file=sys.stderr)
        return 1
    text = ISO_BUILDER.read_text(encoding="utf-8", errors="replace")

    # 1. The packaged unit must be masked by symlink to /dev/null.
    #    Match the two RUN steps together; a symlink without the rm is the
    #    documented way this silently fails to stick.
    mask_re = re.compile(
        r"rm -f\s+/etc/systemd/system/fips\.service\b"
        r"[\s\S]{0,200}?"
        r"ln\s+-sf\s+/dev/null\s+/etc/systemd/system/fips\.service\b"
    )
    check(
        bool(mask_re.search(text)),
        "ISO builder masks fips.service (rm + /dev/null symlink)",
    )

    # 2. A bare `systemctl mask` would look right and do nothing in a container
    #    build; assert the recipe did not rely on it for this unit.
    check(
        not re.search(r"systemctl\s+mask\s+fips\.service", text),
        "does not rely on `systemctl mask` (which does not survive the build)",
    )

    # 3. archipelago-fips.service must still be enabled — masking the packaged
    #    unit is only correct because ours is the enabled one.
    check(
        bool(re.search(r"systemctl\s+enable\s+archipelago-fips\.service", text)),
        "archipelago-fips.service is enabled as the sole supervisor",
    )

    # 4. The mask must come AFTER the .deb install that creates fips.service,
    #    otherwise the rm targets a file that does not exist yet and dpkg's
    #    postinst re-creates it, silently undoing the mask.
    install = text.find("install -y --no-install-recommends /tmp/fips.deb")
    mask = mask_re.search(text)
    if install == -1 or mask is None:
        check(False, "found both the .deb install and the mask (ordering check)")
    else:
        check(
            install < mask.start(),
            "the mask is applied AFTER the fips .deb install (ordering matters: "
            "dpkg extracts /usr/lib/systemd/system/fips.service)",
        )

    print()
    if failures:
        print(f"RESULT: FAIL — {len(failures)} assertion(s) failed")
        return 1
    print("RESULT: PASS — the image masks the packaged fips.service")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
