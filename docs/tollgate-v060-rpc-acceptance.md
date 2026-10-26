## Live RPC acceptance — BOTH lanes

Run through `openwrt.provision-tollgate` against a real Archipelago node
(`archipelago 1.9.1-alpha-dev` built from this branch), driving a QEMU/KVM
OpenWrt guest. Not a shell replay. Each lane was a clean image with a working
route, resolver and package index.

### apk lane — OpenWrt 25.12.5 x86/64

```
opkg not found — using apk (OpenWrt 25.x+)
tollgate-wrt not installed — installing 0.6.0
detected arch: "x86_64" target: "x86-64"
package verified against SHA256SUMS (sha256:82d7dff1957ea6e17b1c5e352162c13eccab7678ba7e1be28eb43c2d04ffe8bb)
tollgate-wrt 0.6.0-r1 is installed and matches the 0.6.0 pin
```

Router read-back: `tollgate-wrt-0.6.0-r1 x86_64 {/feed/net/tollgate-wrt} [installed]`,
`/usr/bin/tollgate-wrt` = 13,508,600 bytes.

### opkg lane — OpenWrt 24.10.8 x86/64

```
Starting TollGate provisioning
opkg update
Installing tollgate-wrt
tollgate-wrt not installed — installing 0.6.0
package verified against SHA256SUMS (sha256:8789811201a96296ee0be5132a07400eeed84ce64a6115b06ced3f8650bccf6a)
tollgate-wrt 0.6.0-r1 is installed and matches the 0.6.0 pin
```

Router read-back: `opkg list-installed` -> `tollgate-wrt - 0.6.0-r1`,
`/usr/bin/tollgate-wrt` = 13,508,600 bytes.

### `openwrt.get-status` on both

```
apk  lane: {"installed":true,"version":"0.6.0-r1","version_known":true,
            "pinned_version":"0.6.0","up_to_date":true,"pkg_manager":"apk"}
opkg lane: {"installed":true,"version":"0.6.0-r1","version_known":true,
            "pinned_version":"0.6.0","up_to_date":true,"pkg_manager":"opkg"}
```

Both sha256 values match the release `SHA256SUMS` **and** the independent
`api.github.com` per-asset digests.

### Still open after this run

1. ~~`wifi down 2>&1; wifi up 2>&1` exits 127 and aborts provisioning after the
   install succeeded.~~ **Fixed in this branch.** `restart_services` now probes
   for the `wifi` command and treats its absence as a device fact rather than a
   provisioning failure, which is what turned the two clean `{"ok":true}`
   responses above from `error` objects on the preceding commit. The
   br-tollgate address check is gated on radio presence too. Raw before/after
   transcripts: `docs/tollgate-v060-rpc-transcripts.md`.
2. A `0.5.0 -> 0.6.0` upgrade and a rollback are still unproven. The
   `rc6 -> 0.6.0` direction **is** measured (see below), but it is not the same
   thing: rc6 is a pre-release of the same version, and `v0.5.0` exists only on
   the Nostr release channel, resolved by PRTA's `scripts/release-matrix.py`,
   which needs MT3000 credentials.
3. `--force-depends` is still argued rather than measured end-to-end; the
   ordering it compensates for (deps installed after the package) is confirmed
   in `tollgate::provision`.
4. ~~`opkg_install_forced` in `opkg.rs` is now unreferenced.~~ **Removed.** It
   shipped a public by-name install helper with no call sites, in the PR that
   removes by-name installs.
5. No physical router has run any of this. Everything here is QEMU x86/64.
   The MT3000 is aarch64 and is a different artifact entirely.

## Upgrade path — measured

Same lab, opkg lane. Installed `0.6.0_rc6-r1` from the rc6 release asset, then
provisioned through the same RPC:

```
tollgate-wrt 0.6.0_rc6-r1 is installed, wanted 0.6.0 — upgrading
package verified against SHA256SUMS (sha256:8789811201a96296ee0be5132a07400eeed84ce64a6115b06ced3f8650bccf6a)
tollgate-wrt 0.6.0-r1 is installed and matches the 0.6.0 pin
```

The binary was genuinely replaced, and the evidence is the **content**, not the
size: rc6's `/usr/bin/tollgate-wrt` is `e42ad747f12c76fdb…` and the post-upgrade
file is `690d9feeeff685f1e…`, while `opkg list-installed` reports `0.6.0-r1`.

Both binaries are **13,508,600 bytes**. (An earlier version of this document
claimed the file grew from 9,487,478 to 13,508,600 bytes. That was wrong —
9,487,478 is the size of the rc6 `.ipk` *archive*, not of the binary inside it,
so the two numbers were not comparable. Same size, different content.)

Note the upgrade **did** need the `--force-*` flags, and it needs them for a
reason that is easy to get backwards. opkg compares versions with `verrevcmp`,
which sorts an rc build **above** the final release it precedes
(`0.6.0_rc6` > `0.6.0`). So rc6 → final is a *downgrade* as far as opkg is
concerned. Measured on the 24.10.8 guest with the pin's package already
installed at rc6 and no flags:

```
Not downgrading package tollgate-wrt on root from 0.6.0_rc6-r1 to 0.6.0-r1.
```

`opkg list-installed` still reported `0.6.0_rc6-r1` afterwards — nothing was
written. The provisioning run only succeeded because `OPKG_INSTALL_LOCAL`
always passes the force set.

Which flag carries it, measured by passing them one at a time — with
`--force-reinstall` alone:

```
Installing tollgate-wrt (0.6.0-r1) to root...
Configuring tollgate-wrt.
```

and the binary then hashes to `690d9fee…`. That is `--force-reinstall`'s
remove-then-install effect doing the work: the old package is removed before the
new one is unpacked, which sidesteps the downgrade refusal entirely.
`--force-downgrade` is not what rescues this particular direction, though it
remains correct for an actual pin rollback.


### The force flags act on a stale package database, not on a republished counter

The `--force-reinstall` doc comment used to claim it covered "`0.6.0-r1`
present, `0.6.0-r2` requested". That case never reaches the installer:
`normalise_version` strips the trailing `-r<digits>` counter, so the pair
compares equal, `decide_install` returns `Skip`, and no install command runs at
all. `version.rs` already asserted this (`drops_the_openwrt_packaging_release_counter`);
a new test, `a_republished_packaging_counter_does_not_trigger_a_reinstall`,
pins the consequence so the flags cannot be "fixed" to cover it.

What the flag *does* do, measured directly: with the package database claiming
`0.6.0-r2` and `/usr/bin/tollgate-wrt` deleted by hand, a plain reinstall is
refused, while

```
opkg install --force-reinstall --force-overwrite --force-depends /tmp/rc6.ipk
```

reports `Installing tollgate-wrt (0.6.0_rc6-r1) to root... / Configuring
tollgate-wrt.` and restores the 13,508,600-byte binary. That is exactly the
damaged state the removed extraction path used to leave behind.
