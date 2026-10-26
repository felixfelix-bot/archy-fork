#!/usr/bin/env bash
# Compile normally; execute unit tests away from real wallets, service buses,
# container storage, processes and networking. Never silently fall back to host.
set -euo pipefail
SCRIPT_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO=${ARCHY_TEST_REPO:-$SCRIPT_REPO}
REPO=$(cd "$REPO" && pwd)
case "${ARCHY_TEST_PACKAGE:-archipelago}" in
  archipelago) test_target=(-p archipelago --bin archipelago) ;;
  archipelago-publishing-tests) test_target=(-p archipelago-publishing-tests --lib) ;;
  archipelago-container) test_target=(-p archipelago-container --lib) ;;
  archipelago-openwrt) test_target=(-p archipelago-openwrt --lib) ;;
  *) echo 'Unsupported isolated test package' >&2; exit 2 ;;
esac

if [[ ${ARCHY_TEST_ISOLATOR:-systemd} == podman ]]; then
  command -v podman >/dev/null
  image=${ARCHY_TEST_IMAGE:?ARCHY_TEST_IMAGE is required for podman isolation}
  cargo_home=${ARCHY_TEST_CARGO_HOME:?ARCHY_TEST_CARGO_HOME is required for podman isolation}
  cargo_home=$(mkdir -p "$cargo_home" && cd "$cargo_home" && pwd)
  artifacts=$(mktemp -d)
  trap 'rm -rf -- "$artifacts"' EXIT
  install -d "$artifacts/runtime/archipelago" "$artifacts/runtime/containers" \
    "$artifacts/runtime/tmp"

  podman run --rm \
    --cpus="${ARCHY_TEST_CPUS:-4}" --memory="${ARCHY_TEST_MEMORY:-4g}" --pids-limit=2048 \
    --cap-drop=all --security-opt=no-new-privileges --read-only \
    --tmpfs /tmp:rw,size=512m --tmpfs /root:rw,size=512m \
    --network=pasta --env CARGO_HOME=/cargo-home \
    --volume "$cargo_home:/cargo-home:rw,Z" \
    --volume "$REPO:/workspace:rw,Z" --volume "$artifacts:/artifacts:rw,Z" \
    --workdir /workspace \
    "$image" \
    cargo test --manifest-path core/Cargo.toml "${test_target[@]}" \
      --locked --no-run --message-format=json \
      --config 'profile.test.package.archipelago.opt-level=0' \
      --config 'profile.test.package.archipelago.debug=0' \
      >"$artifacts/metadata"

  executable=$(python3 - "$artifacts/metadata" <<'PY'
import json,sys
found=[]
for line in open(sys.argv[1]):
 try: item=json.loads(line)
 except json.JSONDecodeError: continue
 if item.get('reason')=='compiler-artifact' and item.get('profile',{}).get('test') and item.get('executable'):
  found.append(item['executable'])
assert len(found)==1, f'Expected one unit test executable, got {len(found)}'
print(found[0])
PY
  )
  case "$executable" in
    /workspace/*) ;;
    *) echo 'Compiled test executable escaped the workspace' >&2; exit 1 ;;
  esac

  podman run --rm \
    --cpus="${ARCHY_TEST_CPUS:-4}" --memory="${ARCHY_TEST_MEMORY:-4g}" --pids-limit=1024 \
    --cap-drop=all --cap-add=chown --cap-add=fowner --cap-add=setuid --cap-add=setgid \
    --security-opt=no-new-privileges --read-only \
    --tmpfs /run:rw,size=64m --tmpfs /root:rw,size=64m --network=none \
    --volume "$artifacts/runtime/tmp:/tmp:rw,Z" \
    --volume "$artifacts/runtime/archipelago:/var/lib/archipelago:rw,Z" \
    --volume "$artifacts/runtime/containers:/var/lib/containers:rw,Z" \
    --volume "$REPO:/workspace:ro,Z" --workdir /workspace/core \
    --env ARCHY_TEST_ISOLATED=1 \
    "$image" "$executable" --test-threads="${ARCHY_TEST_THREADS:-4}" "$@"
  exit
fi

[[ ${ARCHY_TEST_ISOLATOR:-systemd} == systemd ]] || {
  echo 'ARCHY_TEST_ISOLATOR must be systemd or podman' >&2
  exit 2
}
command -v systemd-run >/dev/null
command -v unshare >/dev/null
command -v setpriv >/dev/null
sudo -n true || { echo 'Isolated backend tests require noninteractive sudo for systemd namespaces.' >&2; exit 1; }
metadata=$(mktemp)
trap 'rm -f "$metadata"' EXIT
if ! cargo test --manifest-path "$REPO/core/Cargo.toml" "${test_target[@]}" \
  --locked --no-run --message-format=json --config 'profile.test.package.archipelago.opt-level=0' --config 'profile.test.package.archipelago.debug=0' > "$metadata"; then
    python3 - "$metadata" <<'PYDIAG'
import json,sys
for line in open(sys.argv[1]):
 try: item=json.loads(line)
 except json.JSONDecodeError: continue
 rendered=item.get('message',{}).get('rendered') if item.get('reason')=='compiler-message' else None
 if rendered: print(rendered,file=sys.stderr,end='')
PYDIAG
    exit 1
fi
executable=$(python3 - "$metadata" <<'PY'
import json,sys
found=[]
for line in open(sys.argv[1]):
 try: item=json.loads(line)
 except json.JSONDecodeError: continue
 if item.get('reason')=='compiler-artifact' and item.get('profile',{}).get('test') and item.get('executable'):
  found.append(item['executable'])
assert len(found)==1, f'Expected one unit test executable, got {len(found)}'
print(found[0])
PY
)
[[ -x "$executable" ]]
unit="archy-isolated-tests-$(date +%s)-$$"
sudo -n systemd-run --unit="$unit" --wait --pipe --collect \
  --property="WorkingDirectory=$REPO/core" \
  --property="BindReadOnlyPaths=$REPO" \
  --property=PrivateNetwork=yes --property=PrivateTmp=yes --property=PrivateDevices=yes \
  --property=ProtectSystem=strict --property=ProtectHome=read-only \
  --property=NoNewPrivileges=yes \
  --property='TemporaryFileSystem=/run:rw /var/lib/archipelago:rw /var/lib/containers:rw /root:rw' \
  --setenv=ARCHY_TEST_ISOLATED=1 \
  /usr/bin/unshare --pid --fork --mount-proc --kill-child \
  /usr/bin/setpriv --bounding-set=-all,+chown,+dac_override,+fowner,+setuid,+setgid,+kill \
  "$executable" --test-threads=4 "$@"
