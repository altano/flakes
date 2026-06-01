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
# wherever it runs. The nightly CI job derives the human version string for its
# commit message separately, where the config-blob host is reachable.
#
# Exit status: 0 on success (whether or not anything changed). Tags that fail to
# resolve are warned about and omitted rather than aborting the run.
set -euo pipefail

spec="${WOLF_TRACKED:?WOLF_TRACKED not set — run via 'nix run .#update-containers'}"
out="generated/containers.json"
mkdir -p "$(dirname "$out")"

registry="$(jq -r '.registry' <<<"$spec")"
result='{}'

# Iterate "<image>\t<tag>" pairs from the spec.
while IFS=$'\t' read -r image tag; do
  ref="docker://${registry}/${image}:${tag}"
  echo "resolving ${registry}/${image}:${tag}" >&2

  # --raw fetches the manifest (or multi-arch index) only; manifest-digest
  # computes the tag's content digest the same way the registry does. For a
  # multi-arch tag this is the index digest, which podman resolves per-arch.
  if ! raw="$(skopeo inspect --raw "$ref" 2>/dev/null)"; then
    echo "  WARNING: could not fetch manifest for ${ref} — omitting" >&2
    continue
  fi
  digest="$(printf '%s' "$raw" | skopeo manifest-digest /dev/stdin)"

  result="$(jq -n \
    --argjson acc "$result" \
    --arg image "$image" \
    --arg tag "$tag" \
    --arg fullImage "${registry}/${image}" \
    --arg digest "$digest" \
    '$acc * { ($image): { ($tag): { image: $fullImage, tag: $tag, digest: $digest } } }')"
done < <(jq -r '.images | to_entries[] | .key as $img | .value[] | [$img, .] | @tsv' <<<"$spec")

# Sort keys for stable, reviewable diffs.
printf '%s\n' "$result" | jq -S '.' >"$out"
echo "wrote $out" >&2
