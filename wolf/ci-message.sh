#!/usr/bin/env bash
# ci-message.sh OLD NEW — print a commit message for the digest changes between
# two containers.json snapshots. Used by the nightly workflow.
set -euo pipefail
old="${1:?usage: ci-message.sh OLD NEW}"
new="${2:?usage: ci-message.sh OLD NEW}"
[[ -f "$old" ]] || old=/dev/null

# Changed images, one "name:tag" per line.
changed="$(jq -r --slurpfile o "$old" '
  ($o[0] // {}) as $o |
  to_entries[] | .key as $n | .value | to_entries[] |
  select(.value.digest != ($o[$n][.key].digest // "")) | "\($n):\(.key)"' "$new")"

# Subject: name the Wolf version when stable moved, else a plain count.
if grep -qx "wolf:stable" <<<"$changed"; then
  ver="$(skopeo inspect --override-os linux --override-arch amd64 \
    "docker://$(jq -r '.wolf.stable.image + "@" + .wolf.stable.digest' "$new")" 2>/dev/null |
    jq -r '.Labels["org.opencontainers.image.version"] // empty')"
  echo "wolf: bump stable${ver:+ to $ver}"
else
  echo "wolf: update $(grep -c . <<<"$changed") container pin(s)"
fi

echo
# shellcheck disable=SC2001 # sed is clearer than ${//} for a per-line prefix
sed 's/^/- /' <<<"$changed"
