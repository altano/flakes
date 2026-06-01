"""Tests for wolf config merge script."""

import os
import tomllib
from pathlib import Path

import tomli_w

# Import merge functions from the merge script
sys_path = os.path.dirname(__file__)
import importlib.util

spec = importlib.util.spec_from_file_location("merge_config", os.path.join(sys_path, "merge-config.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

merge_config = mod.merge_config
dedup_paired_clients = mod.dedup_paired_clients


def write_toml(path: Path, data: dict) -> None:
    with path.open("wb") as f:
        tomli_w.dump(data, f)


def read_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


class TestDedup:
    def test_no_duplicates(self):
        clients = [
            {"client_cert": "CERT_A", "app_state_folder": "1"},
            {"client_cert": "CERT_B", "app_state_folder": "2"},
        ]
        result = dedup_paired_clients(clients)
        assert len(result) == 2

    def test_duplicates_last_wins(self):
        clients = [
            {"client_cert": "CERT_A", "app_state_folder": "old", "settings": {"run_uid": 1000}},
            {"client_cert": "CERT_A", "app_state_folder": "new", "settings": {"run_uid": 1001}},
        ]
        result = dedup_paired_clients(clients)
        assert len(result) == 1
        assert result[0]["app_state_folder"] == "new"
        assert result[0]["settings"]["run_uid"] == 1001

    def test_multiple_duplicates(self):
        clients = [
            {"client_cert": "CERT_A", "app_state_folder": "1"},
            {"client_cert": "CERT_B", "app_state_folder": "2"},
            {"client_cert": "CERT_A", "app_state_folder": "3"},
            {"client_cert": "CERT_B", "app_state_folder": "4"},
            {"client_cert": "CERT_A", "app_state_folder": "5"},
        ]
        result = dedup_paired_clients(clients)
        assert len(result) == 2
        certs = {c["client_cert"]: c for c in result}
        assert certs["CERT_A"]["app_state_folder"] == "5"
        assert certs["CERT_B"]["app_state_folder"] == "4"

    def test_empty(self):
        assert dedup_paired_clients([]) == []


class TestMergeConfig:
    def test_first_boot_no_existing(self):
        nix = {
            "uuid": "test-uuid",
            "hostname": "Wolf",
            "profiles": [{"id": "user", "name": "User"}],
        }
        result = merge_config(nix, None, ["paired_clients", "gstreamer"])
        assert result == nix

    def test_preserves_specified_keys(self):
        nix = {
            "uuid": "new-uuid",
            "hostname": "Wolf",
            "profiles": [{"id": "user", "name": "NewUser"}],
        }
        existing = {
            "uuid": "old-uuid",
            "hostname": "OldWolf",
            "paired_clients": [{"client_cert": "CERT_A"}],
            "gstreamer": {"audio": {"default_sink": "something"}},
            "profiles": [{"id": "user", "name": "OldUser"}],
        }
        result = merge_config(nix, existing, ["paired_clients", "gstreamer"])
        # Preserved keys come from existing
        assert result["paired_clients"] == [{"client_cert": "CERT_A"}]
        assert result["gstreamer"] == {"audio": {"default_sink": "something"}}
        # Non-preserved keys come from nix
        assert result["uuid"] == "new-uuid"
        assert result["hostname"] == "Wolf"
        assert result["profiles"] == [{"id": "user", "name": "NewUser"}]

    def test_profiles_overwritten(self):
        nix = {
            "profiles": [{"id": "alan", "name": "Alan"}],
        }
        existing = {
            "profiles": [{"id": "old", "name": "Old"}],
            "paired_clients": [],
        }
        result = merge_config(nix, existing, ["paired_clients"])
        assert result["profiles"] == [{"id": "alan", "name": "Alan"}]

    def test_dedup_during_merge(self):
        nix = {"uuid": "test", "profiles": []}
        existing = {
            "paired_clients": [
                {"client_cert": "CERT_A", "app_state_folder": "old"},
                {"client_cert": "CERT_A", "app_state_folder": "new"},
            ],
        }
        result = merge_config(nix, existing, ["paired_clients"])
        assert len(result["paired_clients"]) == 1
        assert result["paired_clients"][0]["app_state_folder"] == "new"

    def test_missing_preserve_key_in_existing(self):
        nix = {"uuid": "test", "profiles": []}
        existing = {"hostname": "Wolf"}
        result = merge_config(nix, existing, ["paired_clients", "gstreamer"])
        # Keys not in existing are not added
        assert "paired_clients" not in result
        assert "gstreamer" not in result
        assert result["uuid"] == "test"

    def test_empty_preserve_list(self):
        nix = {"uuid": "new", "profiles": []}
        existing = {
            "uuid": "old",
            "paired_clients": [{"client_cert": "CERT_A"}],
        }
        result = merge_config(nix, existing, [])
        assert result["uuid"] == "new"
        assert "paired_clients" not in result
        # config_version bumped because managed keys changed
        assert result["config_version"] == 1


class TestConfigVersion:
    def test_bumps_when_managed_keys_change(self):
        nix = {"uuid": "test", "profiles": [{"id": "alan"}]}
        existing = {
            "uuid": "test",
            "profiles": [{"id": "old"}],
            "config_version": 6,
            "paired_clients": [],
        }
        result = merge_config(nix, existing, ["paired_clients", "config_version"])
        assert result["config_version"] == 7

    def test_no_bump_when_unchanged(self):
        nix = {"uuid": "test", "profiles": [{"id": "alan"}]}
        existing = {
            "uuid": "test",
            "profiles": [{"id": "alan"}],
            "config_version": 6,
            "paired_clients": [],
        }
        result = merge_config(nix, existing, ["paired_clients", "config_version"])
        # Managed keys unchanged, config_version preserved as-is
        assert result["config_version"] == 6

    def test_bumps_from_zero_when_no_existing_version(self):
        nix = {"uuid": "test", "profiles": [{"id": "alan"}]}
        existing = {
            "uuid": "test",
            "profiles": [{"id": "old"}],
        }
        result = merge_config(nix, existing, [])
        assert result["config_version"] == 1

    def test_no_version_on_first_boot(self):
        nix = {"uuid": "test", "profiles": []}
        result = merge_config(nix, None, ["paired_clients"])
        assert "config_version" not in result

    def test_bumps_preserved_version(self):
        """config_version in preserve_keys is preserved then bumped when config changes."""
        nix = {"uuid": "test", "profiles": [{"id": "new"}]}
        existing = {
            "uuid": "test",
            "profiles": [{"id": "old"}],
            "config_version": 5,
        }
        result = merge_config(nix, existing, ["config_version"])
        assert result["config_version"] == 6


class TestMainScript:
    """Integration tests using the full file I/O path."""

    def test_first_boot(self, tmp_path):
        nix_path = tmp_path / "nix.toml"
        live_path = tmp_path / "config.toml"
        nix_data = {"uuid": "test-uuid", "profiles": [{"id": "user", "name": "User"}]}
        write_toml(nix_path, nix_data)

        result = merge_config(nix_data, None, ["paired_clients"])

        write_toml(live_path, result)
        written = read_toml(live_path)
        assert written["uuid"] == "test-uuid"
        assert written["profiles"] == [{"id": "user", "name": "User"}]

    def test_merge_preserves_and_overwrites(self, tmp_path):
        nix_path = tmp_path / "nix.toml"
        live_path = tmp_path / "config.toml"

        existing_data = {
            "uuid": "old-uuid",
            "paired_clients": [{"client_cert": "CERT_A", "app_state_folder": "1"}],
            "gstreamer": {"video": {"source": "test"}},
            "profiles": [{"id": "old", "name": "Old"}],
            "config_version": 6,
        }
        write_toml(live_path, existing_data)

        nix_data = {
            "uuid": "new-uuid",
            "hostname": "TestWolf",
            "profiles": [{"id": "alan", "name": "Alan"}],
        }
        write_toml(nix_path, nix_data)

        existing = read_toml(live_path)
        result = merge_config(nix_data, existing, ["paired_clients", "gstreamer", "config_version"])

        write_toml(live_path, result)
        written = read_toml(live_path)

        assert written["uuid"] == "new-uuid"
        assert written["hostname"] == "TestWolf"
        assert written["profiles"] == [{"id": "alan", "name": "Alan"}]
        assert written["paired_clients"] == [{"client_cert": "CERT_A", "app_state_folder": "1"}]
        assert written["gstreamer"] == {"video": {"source": "test"}}
        # config_version bumped because managed keys changed
        assert written["config_version"] == 7

    def test_atomic_write(self, tmp_path):
        live_path = tmp_path / "config.toml"
        data = {"uuid": "test"}
        tmp_file = live_path.with_suffix(".tmp")

        write_toml(tmp_file, data)
        os.replace(tmp_file, live_path)

        assert live_path.exists()
        assert not tmp_file.exists()
        assert read_toml(live_path) == data
