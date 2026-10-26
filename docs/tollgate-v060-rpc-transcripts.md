# TollGate 0.6.0 provisioning — raw RPC transcripts

Attestation for the claims in `tollgate-v060-rpc-acceptance.md`. These are the
literal response bodies and node log lines, captured on the t440 lab host, not
reconstructions. Timestamps are the node's own.

Node: `1.9.1-alpha-dev`, `ARCHIPELAGO_BIND=10.99.99.2:5678`, lab bridge
`archy-lab-br` (`10.99.99.2/24`), QEMU/KVM guests from
`archy-tollgate-e2e/scripts/lab.py`. Router provisioned over
`openwrt.provision-tollgate` JSON-RPC; the guest is reached at `10.99.99.1`
(root / lab password), which is what `host` in the params refers to.

## opkg lane — OpenWrt 24.10.8 (x86/64), fresh install + upgrade

Request `id:40`, router already carrying `0.6.0_rc6-r1`:

```
{"result":{"host":"10.99.99.1","mint_url":"http://10.99.99.2:3338","ok":true,"ssid":"archipelago"},"error":null}
```

Node log for the same call:

```
2026-10-26T00:45:36.849469Z  INFO archipelago_openwrt::tollgate: [10.99.99.1] Starting TollGate provisioning
2026-10-26T00:45:40.498806Z  INFO archipelago_openwrt::tollgate::install: [10.99.99.1] tollgate-wrt 0.6.0_rc6-r1 is installed, wanted 0.6.0 — upgrading
2026-10-26T00:45:43.704645Z  INFO archipelago_openwrt::tollgate::install: [10.99.99.1] package verified against SHA256SUMS (sha256:8789811201a96296ee0be5132a07400eeed84ce64a6115b06ced3f8650bccf6a)
2026-10-26T00:46:21.339187Z  INFO archipelago_openwrt::tollgate::install: [10.99.99.1] tollgate-wrt 0.6.0-r1 is installed and matches the 0.6.0 pin
2026-10-26T00:46:28.365320Z  INFO archipelago_openwrt::tollgate: [10.99.99.1] no wifi command on this device — skipping wireless reload (br-tollgate stays unclaimed)
2026-10-26T00:46:40.063679Z  INFO archipelago_openwrt::tollgate: [10.99.99.1] TollGate provisioning complete
```

## apk lane — OpenWrt 25.12.5 (x86/64), fresh install

Request `id:42`:

```
{"result":{"host":"10.99.99.1","mint_url":"http://10.99.99.2:3338","ok":true,"ssid":"archipelago"},"error":null}
```

Node log for the same call:

```
2026-10-26T00:53:30.185700Z  INFO archipelago_openwrt::tollgate: [10.99.99.1] Starting TollGate provisioning
2026-10-26T00:53:37.801802Z  INFO archipelago_openwrt::tollgate::install: [10.99.99.1] package verified against SHA256SUMS (sha256:82d7dff1957ea6e17b1c5e352162c13eccab7678ba7e1be28eb43c2d04ffe8bb)
2026-10-26T00:54:11.008598Z  INFO archipelago_openwrt::tollgate::install: [10.99.99.1] tollgate-wrt 0.6.0-r1 is installed and matches the 0.6.0 pin
2026-10-26T00:54:19.053196Z  INFO archipelago_openwrt::tollgate: [10.99.99.1] no wifi command on this device — skipping wireless reload (br-tollgate stays unclaimed)
2026-10-26T00:54:30.704341Z  INFO archipelago_openwrt::tollgate: [10.99.99.1] TollGate provisioning complete
```

## Failure shape before the wifi fix

Same node, same lab, the preceding commit. The install and verification
succeeded and the RPC still reported failure:

```
{"result":null,"error":{"code":-1,"message":"Operation failed. Check server logs for details.","data":null}}
```

with the underlying cause in the log:

```
ERROR RPC error on openwrt.provision-tollgate: command `wifi down 2>&1; wifi up 2>&1` exited with code 127: ash: wifi: not found
```

That is the defect the `restart_services` change addresses: `provision-tollgate`
could not distinguish "install failed" from "install succeeded, radio reload
unavailable".

## opkg downgrade refusal — measured directly on the 24.10.8 guest

With the pin's package present at `0.6.0_rc6-r1`, installing the 0.6.0 `.ipk`
with no flags:

```
Not downgrading package tollgate-wrt on root from 0.6.0_rc6-r1 to 0.6.0-r1.
```

`opkg list-installed` afterwards still reported `0.6.0_rc6-r1`; nothing was
written. `verrevcmp` sorts an rc build above its final release, so this
direction is a downgrade to opkg.

The same install with `--force-reinstall` alone:

```
Installing tollgate-wrt (0.6.0-r1) to root...
Configuring tollgate-wrt.
```

followed by `opkg list-installed` → `tollgate-wrt - 0.6.0-r1`.

## Binary content, both releases

Both `x86_64` payloads are the same size; the content differs.

```
rc6   /usr/bin/tollgate-wrt  13,508,600 B  e42ad747f12c76fdbf790d6e6edef76d1a61bbf3657d9ec89af59ada8941083d
0.6.0 /usr/bin/tollgate-wrt  13,508,600 B  690d9feeeff685f1edd8d27134adca8952a449c0a64f594196a96fb70aceed7d
```

Hashes computed by extracting `data.tar.gz` from each `.ipk` and hashing
`usr/bin/tollgate-wrt`.

## What these transcripts do not show

- No physical router. All of the above is QEMU x86/64.
- No rollback leg, and no `v0.5.0` baseline — that needs the MT3000 bench and
  `scripts/release-matrix.py`, which requires router credentials.
- Nothing about aarch64; the MT3000 payload is a different artifact.
