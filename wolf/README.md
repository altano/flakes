# wolf

A NixOS module for [Wolf](https://games-on-whales.github.io/wolf/) (Games on
Whales) — multi-user cloud gaming over Moonlight.

## Features

- Fully configurable via this nix module. Writes Wolf's toml config.
- Specify apps (stock apps like Steam, or custom apps).
- Define profiles w/ icon, apps, PIN code, etc.
- Can configure NVIDIA GPU drivers (AMD/Intel not yet supported).

## Usage

Add the input:

```nix
{
  inputs.wolf = {
    url = "github:altano/flakes?dir=wolf";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Import the module and configure the service (NVIDIA + podman example):

```nix
{ config, ... }:
{
  imports = [ inputs.wolf.nixosModules.default ];

  services.wolf = {
    enable = true;
    uuid = "c0c283f1-5f7b-4467-a21d-472283c249b7"; # stable; changing it re-pairs all clients
    internalIP = "10.10.40.40";
    openFirewall = true;
    backend = "podman";
    gpu = {
      vendor = "nvidia";
      nvidiaPackage = config.hardware.nvidia.package;
    };

    profiles = [
      {
        name = "alan";
        apps = [
          {
            name = "steam";
            prefetch = true;
          }
          { name = "firefox"; }
          { name = "desktop"; }
        ];
      }
    ];
  };
}
```

## Complete Examples

### Basic, no GPU, one profile

The minimum to get a working host: identity (`uuid`), the IP Moonlight connects
to, and a socket for the launcher. `gpu.vendor` defaults to `none`, so no
GPU-specific config is added.

```nix
{
  imports = [ inputs.wolf.nixosModules.default ];

  services.wolf = {
    enable = true;
    uuid = "c0c283f1-5f7b-4467-a21d-472283c249b7"; # stable; changing it re-pairs all clients
    internalIP = "192.168.1.50";
    openFirewall = true;
    socketPath = "/var/run/wolf/wolf.sock"; # required by the wolf-ui launcher

    profiles = [
      {
        name = "me";
        apps = [
          { name = "firefox"; }
          { name = "desktop"; }
        ];
      }
    ];
  };
}
```

Moonlight shows one host; opening it lands on the **Launcher** (Wolf UI), where
the `me` profile offers Firefox and an XFCE desktop.

### NVIDIA GPU, multiple profiles

A fuller setup: NVIDIA passthrough, persistent TLS cert/key (so pairings
survive rebuilds — here via [agenix](https://github.com/ryantm/agenix), any
secrets tool works), image prefetching, per-profile icons + a PIN, and a bit of
per-app tuning.

```nix
{ config, pkgs, ... }:
{
  imports = [ inputs.wolf.nixosModules.default ];

  # Host NVIDIA driver (the module auto-enables the CDI container toolkit).
  hardware.nvidia = {
    open = true; # Ada/Ampere and newer; false for older GPUs
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.production;
  };
  hardware.graphics.enable = true;

  services.wolf = {
    enable = true;
    uuid = "c0c283f1-5f7b-4467-a21d-472283c249b7";
    internalIP = "10.10.40.40";
    openFirewall = true;
    socketPath = "/var/run/wolf/wolf.sock";

    # Persist the pairing identity across rebuilds.
    privateCertPath = config.age.secrets."wolf-cert".path;
    privateKeyPath = config.age.secrets."wolf-key".path;

    gpu = {
      vendor = "nvidia";
      nvidiaPackage = config.hardware.nvidia.package;
    };

    # OPTIONAL: Append low-latency DXVK tuning to the stock Steam app (not restated).
    appExtraEnv.steam = [
      "DXVK_CONFIG=dxgi.syncInterval = 0; dxgi.maxFrameLatency = 1; dxgi.maxFrameRate = 120"
    ];

    profiles = [
      {
        name = "alan";
        icon = ./profile-pictures/alan.png;
        apps = [
          {
            name = "steam";
            prefetch = true; # pre-pull the image at boot
          }
          {
            name = "firefox";
            prefetch = true;
          }
          { name = "desktop"; }
          { name = "retroarch"; }
        ];
      }
      {
        name = "guest";
        pin = [ 1 2 3 4 ]; # PIN required to reveal this profile's apps
        apps = [ { name = "firefox"; } ];
      }
    ];
  };
}
```

### Adding your own apps

The built-in catalog lives in [`apps.nix`](./apps.nix). Register additional
apps (same `[[profiles.apps]]` schema) via `services.wolf.extraApps`, then
reference them by name from a profile:

```nix
{
  services.wolf.extraApps.mygame = {
    title = "My Game";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "MyGame";
      image = "ghcr.io/me/mygame@sha256:..."; # pin your own digest
    };
  };
  services.wolf.profiles = [
    {
      name = "me";
      apps = [ { name = "mygame"; } ];
    }
  ];
}
```

`extraApps` is merged over the built-ins, so you can also override a built-in
app by reusing its name.

### Customizing a built-in app

To tweak a stock catalog app, you have two options.

**Option A — append env via `appExtraEnv`.** Best when you only need to add
environment variables (e.g. per-host tuning). Keys must name a built-in app:

```nix
{
  services.wolf.appExtraEnv.steam = [
    "DXVK_CONFIG=dxgi.syncInterval = 0; dxgi.maxFrameRate = 120"
  ];
}
```

The values are appended to the app's existing env — you don't restate the
defaults.

**Option B — redefine the app via `extraApps`.** Best when you need to change
more than env (image, mounts, caps, …). Don't reference the built-in; define
your own app (reusing the name overrides the built-in) and reference that:

```nix
{
  services.wolf.extraApps.steam = {
    title = "Steam";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfSteam";
      image = "ghcr.io/games-on-whales/steam@sha256:..."; # pin your own
      env = [ "PROTON_LOG=1" "RUN_SWAY=true" ];
      # ...full runner definition...
    };
  };
}
```

## Key options

| Option                | Default       | Description                                                                                                                  |
| --------------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `backend`             | `podman`      | OCI backend (`podman`/`docker`).                                                                                             |
| `wolfTag`             | `stable`      | Which pinned Wolf tag to run (`stable`/`alpha`).                                                                             |
| `gpu.vendor`          | `none`        | `none` (no GPU config) or `nvidia` (driver volume via `wolf-nvidia-vol` + CDI). `intel`/`amd` reserved, not yet implemented. |
| `gpu.useCDI`          | `true`        | NVIDIA via `--device=nvidia.com/gpu=all` vs enumerating `/dev/nvidia*`.                                                      |
| `pulseImage`          | pinned        | PulseAudio sidecar image (`WOLF_PULSE_IMAGE`).                                                                               |
| `ports.*`             | Wolf defaults | Firewall ports opened when `openFirewall`.                                                                                   |
| `supportHevc`         | `null`        | config.toml `support_hevc` (null = leave to Wolf / preserved).                                                               |
| `defaultRun{Uid,Gid}` | `null`        | `WOLF_DEFAULT_RUN_{UID,GID}` for newly paired clients (null = Wolf default 1000).                                            |
| `extraApps`           | `{}`          | Consumer-supplied catalog entries (override a built-in by reusing its name).                                                 |
| `appExtraEnv`         | `{}`          | Append env to a built-in app, keyed by app name.                                                                             |
| `extraEnvironment`    | `{}`          | Escape hatch for any other Wolf-server env var (`RUST_BACKTRACE`, `GST_DEBUG`, …).                                           |
| `extraConfig`         | `{}`          | Escape hatch for any other top-level `config.toml` field (overrides the preserved live value).                               |

### config.toml / env coverage

Every documented [Wolf config option](https://games-on-whales.github.io/wolf/stable/user/configuration.html)
is reachable:

- **Wolf-server env** — modelled options above (`logLevel`, `pulseImage`,
  `stopContainerOnExit`, `gpu.renderNode`, `private{Cert,Key}Path`,
  `defaultRun{Uid,Gid}`, …). The container-internal path vars (`WOLF_CFG_FILE`,
  `HOST_APPS_STATE_FOLDER`, `WOLF_DOCKER_SOCKET`, `XDG_RUNTIME_DIR`) are fixed and
  driven by the host-side mounts — set `configDir`/`dataDir`/`backend` instead.
  Anything else: `extraEnvironment`.
- **App-container env** (`RUN_SWAY`, `XKB_DEFAULT_*`, `PROTON_LOG`, …) — set
  per app in the catalog / `extraApps` / `appExtraEnv`.
- **config.toml** — `uuid`, `hostname`, `profiles` (and their nested
  `apps`/`runner`/`video`/`audio`) are generated; `support_hevc` via
  `supportHevc`; anything else via `extraConfig`.

NOTE: config.toml contains runtime-managed, mutable state (`paired_clients`, `gstreamer`, `config_version`) which is
**preserved** across deploys by the merge step (see `preserveKeys` option); set
`supportHevc`/`extraConfig` to override a preserved key declaratively.

## Updating pinned digests

Wolf ships as a moving Docker tag (`ghcr.io/games-on-whales/wolf:stable`), and
it launches a fleet of companion/app containers (pulseaudio, steam, firefox,
…) that are likewise published as moving tags. This flake records the current
digest of each in [`generated/containers.json`](./generated/containers.json) so deploys are reproducible, and a nightly CI job refreshes those digests.

`generated/containers.json` is regenerated from the live registry with
[`update-containers.sh`](./update-containers.sh). The set of images/tags to pin is **derived from
the catalog** (the `trackedImages` flake output = every `imageRef` in
[`apps.nix`](./apps.nix) plus a small core list in
[`flake.nix`](./flake.nix)), so adding an app needs no second list. The
`update-containers` package embeds that list and passes it to the script, so:

```bash
nix run .#update-containers     # from this directory
```

A nightly GitHub Actions workflow runs this and commits any digest changes to
`main`. The flake only consumes the `stable` Wolf tag; `buildcache`/`alpha` are
tracked for reference (`buildcache` is a CI layer-cache manifest, not a runnable
release).
