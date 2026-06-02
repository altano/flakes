#!/usr/bin/env bash

# update-containers.sh — regenerate generated/containers.json from the registry.
#
# The set of images/tags to pin comes from $WOLF_TRACKED (a JSON object
# { registry, images: { name: [tag, ...] } }), which the flake derives from the
# app catalog + core image list and embeds into the `update-containers` package.
# Run it as:
#   nix run .#update-containers      # from the wolf/ directory
#
# For each image:tag we fetch ONLY the manifest (skopeo inspect --raw, ~KB — not
# the layers or config blob) and record its digest. Output is pure
# {image, tag, digest} — no labels — so it's byte-for-byte deterministic
# wherever it runs.
#
# IMPORTANT: this is all-or-nothing. If ANY image fails to resolve (network,
# auth, rate-limit, bad digest) the script exits non-zero and leaves the
# existing containers.json untouched — it never writes a partial or empty file.
# A degenerate {} pin file would break every consumer of the flake, so a
# transient registry failure must fail the run, not silently truncate it.
set -euo pipefail

# nixpkgs skopeo requires a v2 registries.conf. Some hosts (notably GitHub
# Actions runners) ship a v1 one at the default /etc/containers/registries.conf,
# which makes EVERY skopeo call fatal. Point skopeo at our own minimal v2 config.
reg_conf="$(mktemp)"
printf 'unqualified-search-registries = []\n' >"$reg_conf"
export CONTAINERS_REGISTRIES_CONF="$reg_conf"
errf="$(mktemp)"
trap 'rm -f "$reg_conf" "$errf"' EXIT

spec="${WOLF_TRACKED:?WOLF_TRACKED not set — run via 'nix run .#update-containers'}"
out="generated/containers.json"

registry="$(jq -r '.registry' <<<"$spec")"
result='{}'
total=0
ok=0
failures=()

# Iterate "<image>\t<tag>" pairs from the spec.
while IFS=$'\t' read -r image tag; do
  total=$((total + 1))
  ref="docker://${registry}/${image}:${tag}"
  echo "resolving ${registry}/${image}:${tag}" >&2

  # --raw fetches the manifest (or multi-arch index) only; manifest-digest
  # computes the tag's content digest the same way the registry does. For a
  # multi-arch tag this is the index digest, which podman resolves per-arch.
  # On failure we print skopeo's actual error (not a generic message) so CI
  # logs show why.
  if ! raw="$(skopeo inspect --retry-times 3 --raw "$ref" 2>"$errf")"; then
    echo "  ERROR: skopeo could not fetch ${ref}:" >&2
    sed 's/^/    /' "$errf" >&2
    failures+=("${image}:${tag}")
    continue
  fi
  digest="$(printf '%s' "$raw" | skopeo manifest-digest /dev/stdin 2>"$errf" || true)"
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "  ERROR: bad digest for ${ref}: '${digest}'" >&2
    sed 's/^/    /' "$errf" >&2
    failures+=("${image}:${tag}")
    continue
  fi

  result="$(jq -n \
    --argjson acc "$result" \
    --arg image "$image" \
    --arg tag "$tag" \
    --arg fullImage "${registry}/${image}" \
    --arg digest "$digest" \
    '$acc * { ($image): { ($tag): { image: $fullImage, tag: $tag, digest: $digest } } }')"
  ok=$((ok + 1))
done < <(jq -r '.images | to_entries[] | .key as $img | .value[] | [$img, .] | @tsv' <<<"$spec")

# Refuse to write anything unless every tracked image resolved.
if [[ $total -eq 0 ]]; then
  echo "ERROR: no images in WOLF_TRACKED spec" >&2
  exit 1
fi
if [[ ${#failures[@]} -gt 0 || $ok -ne $total ]]; then
  echo "ERROR: resolved ${ok}/${total} images; failures: ${failures[*]:-none}." >&2
  echo "Leaving ${out} untouched." >&2
  exit 1
fi

# All good — write atomically (sorted keys for stable, reviewable diffs).
mkdir -p "$(dirname "$out")"
printf '%s\n' "$result" | jq -S '.' >"$out.tmp"
mv "$out.tmp" "$out"
echo "wrote $out (${ok} images)" >&2
