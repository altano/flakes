#!/usr/bin/env bash
# ci-message.sh OLD NEW — print a commit message for the digest changes between
# two containers.json snapshots. Used by the nightly workflow.
#
# The commit message is the ONLY thing written to stdout (the workflow redirects
# it to a file). Every diagnostic goes to stderr so it still shows up in the CI
# log even when stdout is captured. On any failure the ERR trap reports the line
# number, and under CI we xtrace every command so a silent `set -e` abort — like
# the one that left us with a bare "exit code 1" — can't happen again.
set -euo pipefail
trap 's=$?; echo "::error::ci-message.sh failed (exit $s) at line $LINENO" >&2' ERR
if [[ -n "${CI:-}" || -n "${CI_DEBUG:-}" ]]; then
  set -x
fi

old="${1:?usage: ci-message.sh OLD NEW}"
new="${2:?usage: ci-message.sh OLD NEW}"
[[ -f "$old" ]] || old=/dev/null

# Changed images, one "name:tag" per line.
changed="$(jq -r --slurpfile o "$old" '
  ($o[0] // {}) as $o |
  to_entries[] | .key as $n | .value | to_entries[] |
  select(.value.digest != ($o[$n][.key].digest // "")) | "\($n):\(.key)"' "$new")"
echo "ci-message.sh: changed images:" >&2
sed 's/^/  /' <<<"$changed" >&2

# Subject: name the Wolf version when stable moved, else a plain count.
if grep -qx "wolf:stable" <<<"$changed"; then
  ref="docker://$(jq -r '.wolf.stable.image + "@" + .wolf.stable.digest' "$new")"
  echo "ci-message.sh: inspecting $ref for its version label" >&2
  # No `2>/dev/null`: let skopeo's error reach the CI log, and keep it on its own
  # line (not piped into jq) so the ERR trap reports the right command on failure.
  inspect="$(skopeo inspect --override-os linux --override-arch amd64 "$ref")"
  ver="$(jq -r '.Labels["org.opencontainers.image.version"] // empty' <<<"$inspect")"
  echo "wolf: bump stable${ver:+ to $ver}"
else
  echo "wolf: update $(grep -c . <<<"$changed") container pin(s)"
fi

echo
# shellcheck disable=SC2001 # sed is clearer than ${//} for a per-line prefix
sed 's/^/- /' <<<"$changed"
