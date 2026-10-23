#!/usr/bin/env bash
# Push the PR branch to the ngit remote using an ephemeral signer config,
# so the nsec never lands in argv, the repo config, or ~/.gitconfig.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/worktrees/archy-fips-bump"

KEY="$HOME/.hermes/keys/ngit/onekey/k1"
umask 077
CFG="$(mktemp /tmp/.ngit-signer-XXXXXX)"
cleanup() { shred -u "$CFG" 2>/dev/null || rm -f "$CFG"; }
trap cleanup EXIT

NEXTSEC="$(grep -o 'nsec1[0-9a-z]\{58,\}' "$KEY" | head -1)"
printf '[nostr]\n\tnsec = %s\n' "$NEXTSEC" > "$CFG"
chmod 600 "$CFG"
echo "signer npub: $(nak encode npub "$(nak key public "$NEXTSEC")")"

GIT_CONFIG_GLOBAL="$CFG" git push --no-verify ngit \
  refs/heads/pr/fips-bump-0.5.3:refs/heads/pr/fips-bump-0.5.3 2>&1 | tail -25
