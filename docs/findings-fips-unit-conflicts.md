# Findings — `Conflicts=fips.service` is bidirectional (review MEDIUM #3)

**Verdict: the review is correct, and the defect is larger than the review states.
`Conflicts=` alone does not guarantee "one daemon, one supervisor".**

Evidence gathered on this branch. Not a guess — each claim below cites an
observed command or a line of code.

## What the code actually is

`image-recipe/configs/archipelago-fips.service` adds:

```
Conflicts=fips.service
```

with a comment asserting "the packaged unit concedes". `Conflicts=` is
**symmetric** in systemd: starting either unit stops the other. Nothing makes
`fips.service` the one that yields.

## Why symmetry is not enough here

1. **The upstream unit is installed AND enabled.** The ISO installs the FIPS
   `.deb` (`build-auto-installer-iso.sh:464`), and the package's postinst enables
   `fips.service`. Observed on this host:
   `UnitFileState=enabled`, `FragmentPath=/usr/lib/systemd/system/fips.service`,
   with `Conflicts=` containing only `shutdown.target` — i.e. the upstream unit
   does **not** know about `archipelago-fips.service`.

2. **Both are `WantedBy=multi-user.target`.** On any boot where onboarding has
   already happened, systemd has two enabled units racing for the same TUN and
   the same ports. `Conflicts=` makes the race *deterministic-ish* — one stops
   the other — but which one wins depends on transaction ordering, not on a
   declared precedence.

3. **The loser is masked, never the intended loser.** `fips::service::mask()`
   exists (`service.rs:176`) and calls `disable` + `mask`, but **it has no
   callers** — `grep -rn "mask(" core/archipelago/src/` finds only its own
   definition. So nothing in the product ever disables the unit it intends to
   concede.

4. **The activation path can start the upstream unit deliberately.**
   `activation_unit()` (`service.rs:145`) returns `archipelago-fips.service` if
   that unit exists, **else `fips.service`**. On a node where the archipelago
   unit is absent (upstream-package-only nodes, which that fallback exists to
   serve), the app starts `fips.service` — and the `Conflicts=` line in the
   *other* file then stops `archipelago-fips.service` if it is present. The
   fallback and the Conflicts directive encode opposite assumptions about which
   unit loses.

Consequence: the PR body and the unit comment claim an invariant the artifacts do
not enforce. The original defect (two units crash-looping on the same ports) is
*made less likely*, not eliminated.

## The honest options

**A. Mask the packaged unit from the image (recommended for the ISO path).**
The ISO already mask-by-symlink for exactly this class of problem
(`build-auto-installer-iso.sh:647`: "`systemctl mask` alone doesn't stick because
the real .service file is already in place — explicit rm + /dev/null symlink is
what sticks"). Doing the same for `fips.service` in the image would make
archipelago the sole supervisor by construction on every ISO-built node, and
leave `Conflicts=` as a belt-and-braces second line of defence.

*Cost:* breaks the `activation_unit()` fallback for upstream-package-only nodes —
but those nodes are not ISO-built, so they never receive the mask. The fallback
stays correct for them. **This is the option that matches the existing design.**

**B. Add the reciprocal directive via a drop-in.**
Ship `/etc/systemd/system/fips.service.d/archipelago.conf` on archipelago images
with `Conflicts=archipelago-fips.service`. Symmetric with A's intent. Does **not**
establish which one yields, so the race remains — it only ensures both directions
are declared. Weaker than A for no benefit here.

**C. Do nothing and correct the comment.** Keep `Conflicts=`, delete the claim
that the packaged unit "concedes", and document that the two units are mutually
exclusive with ordering decided by systemd. Cheapest and honest, but leaves the
boot race.

## Recommendation

**A, plus C's wording correction.** A is the only option that makes the stated
invariant true rather than merely likely, it mirrors a pattern the image already
uses for the same failure mode, and it does not affect the upstream-package-only
nodes the fallback serves.

Not implemented in this branch: it changes image build behaviour and needs its own
RED→GREEN test (assert both units cannot be active simultaneously across a
simulated boot ordering), which is a larger change than a review-response commit
should carry. Recorded here so the next worker starts from evidence instead of
re-deriving it.
