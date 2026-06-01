"""Merge Nix-generated Wolf config with existing config.toml, preserving runtime state."""

import os
import sys
import tomllib
from pathlib import Path

import tomli_w


def dedup_paired_clients(clients: list[dict]) -> list[dict]:
    """Deduplicate paired_clients by client_cert, keeping the last entry for each cert."""
    seen: dict[str, dict] = {}
    for client in clients:
        cert = client.get("client_cert", "")
        seen[cert] = client
    return list(seen.values())


def merge_config(
    nix_config: dict,
    existing_config: dict | None,
    preserve_keys: list[str],
) -> dict:
    """Merge nix-generated config with existing config, preserving specified keys."""
    if existing_config is None:
        return nix_config

    merged = dict(nix_config)
    for key in preserve_keys:
        if key in existing_config:
            value = existing_config[key]
            if key == "paired_clients" and isinstance(value, list):
                value = dedup_paired_clients(value)
            merged[key] = value

    # Auto-increment config_version if the nix-managed portion changed.
    # Compare everything except preserved keys to detect changes.
    skip_keys = set(preserve_keys)
    old_managed = {k: v for k, v in existing_config.items() if k not in skip_keys}
    new_managed = {k: v for k, v in merged.items() if k not in skip_keys}
    if old_managed != new_managed:
        merged["config_version"] = merged.get("config_version", 0) + 1

    return merged


def main() -> None:
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <nix-config.toml> <live-config.toml> [preserve-key ...]", file=sys.stderr)
        sys.exit(1)

    nix_config_path = Path(sys.argv[1])
    live_config_path = Path(sys.argv[2])
    preserve_keys = sys.argv[3:]

    with nix_config_path.open("rb") as f:
        nix_config = tomllib.load(f)

    existing_config = None
    if live_config_path.exists():
        with live_config_path.open("rb") as f:
            existing_config = tomllib.load(f)

    merged = merge_config(nix_config, existing_config, preserve_keys)

    # Write atomically via temp file + rename
    live_config_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = live_config_path.with_suffix(".tmp")
    with tmp_path.open("wb") as f:
        tomli_w.dump(merged, f)
    os.replace(tmp_path, live_config_path)


if __name__ == "__main__":
    main()
