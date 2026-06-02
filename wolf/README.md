# wolf

A NixOS module for [Wolf](https://games-on-whales.github.io/wolf/), a part of
Games on Whales (a platform for multi-user, cloud gaming over Moonlight).

## Features

- Fully configurable via this nix module. Manages Wolf's toml config.
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
    # Stable host ID Moonlight uses to recognize this paired host (any UUID).
    # Generate one with `uuidgen`. Changing it forces all clients to re-pair.
    uuid = "00000000-0000-0000-0000-000000000000";
    openFirewall = true;
    gpu.vendor = "nvidia";

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

The bare minimum: a `uuid` and a profile. `gpu.vendor` defaults to `none`, so no
GPU config is added, and `internalIP`/`socketPath` are auto-detected/defaulted.

```nix
{
  imports = [ inputs.wolf.nixosModules.default ];

  services.wolf = {
    enable = true;
    # Stable host ID Moonlight uses to recognize this paired host (any UUID).
    # Generate one with `uuidgen`. Changing it forces all clients to re-pair.
    uuid = "00000000-0000-0000-0000-000000000000";
    openFirewall = true;

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

### NVIDIA GPU, basic config/profile

The basic config plus NVIDIA passthrough. You set up the host driver; the module
builds the driver volume (via `wolf-nvidia-vol`) and wires up CDI from one `gpu`
block.

```nix
{ config, ... }:
{
  imports = [ inputs.wolf.nixosModules.default ];

  # Host NVIDIA driver (the module auto-enables the CDI container toolkit).
  hardware = {
    graphics.enable = true;
    nvidia = {
      open = true; # Ada/Ampere and newer; false for older GPUs
      modesetting.enable = true;
      package = config.boot.kernelPackages.nvidiaPackages.production;
    };
  };

  services.wolf = {
    enable = true;
    # Stable host ID Moonlight uses to recognize this paired host (any UUID).
    # Generate one with `uuidgen`. Changing it forces all clients to re-pair.
    uuid = "00000000-0000-0000-0000-000000000000";
    openFirewall = true;
    gpu.vendor = "nvidia";

    profiles = [
      {
        name = "me";
        apps = [
          { name = "steam"; }
          { name = "firefox"; }
          { name = "desktop"; }
        ];
      }
    ];
  };
}
```

### NVIDIA GPU, advanced config, multiple profiles

A fuller setup: NVIDIA passthrough, persistent TLS cert/key (so pairings
survive rebuilds — here via [agenix](https://github.com/ryantm/agenix), any
secrets tool works), image prefetching, per-profile icons + a PIN, and a bit of
per-app tuning.

```nix
{ config, pkgs, ... }:
{
  imports = [ inputs.wolf.nixosModules.default ];

  # Host NVIDIA driver (the module auto-enables the CDI container toolkit).
  hardware = {
    graphics.enable = true;
    nvidia = {
      open = true; # Ada/Ampere and newer; false for older GPUs
      modesetting.enable = true;
      package = config.boot.kernelPackages.nvidiaPackages.production;
    };
  };

  services.wolf = {
    enable = true;
    # Stable host ID Moonlight uses to recognize this paired host (any UUID).
    # Generate one with `uuidgen`. Changing it forces all clients to re-pair.
    uuid = "00000000-0000-0000-0000-000000000000";
    openFirewall = true;
    gpu.vendor = "nvidia";

    # OPTIONAL: Persist the pairing identity across rebuilds.
    privateCertPath = config.age.secrets."wolf-cert".path;
    privateKeyPath = config.age.secrets."wolf-key".path;

    # OPTIONAL: append low-latency DXVK tuning to Steam
    appExtraEnv.steam = [
      (
        "DXVK_CONFIG="
        + "dxgi.syncInterval = 0;"
        + "dxgi.maxFrameLatency = 1;"
        + "dxgi.maxFrameRate = 120"
      )
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
    "DXVK_CONFIG=dxgi.maxFrameRate = 120"
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

## Configuration

### Required Options

| Option   | Type | Default      | Description                                                                                                                          |
| -------- | ---- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `enable` | bool | `false`      | Enable the Wolf service (set to `true`).                                                                                             |
| `uuid`   | str  | _(required)_ | Stable host ID Moonlight uses to recognize this paired host. Changing it forces all clients to re-pair. Generate one with `uuidgen`. |

### Key Options

| Option                               | Type               | Default               | Description                                                                                                       |
| ------------------------------------ | ------------------ | --------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `appExtraEnv`                        | attrs of list      | `{}`                  | Append env to a built-in app, keyed by app name.                                                                  |
| `backend`                            | `podman`\|`docker` | `podman`              | OCI container backend.                                                                                            |
| `extraApps`                          | attrs              | `{}`                  | Consumer catalog entries (override a built-in by reusing its name).                                               |
| `gpu.nvidiaPackage`                  | null\|pkg          | host driver           | NVIDIA driver package; defaults to `config.hardware.nvidia.package` when `gpu.vendor = "nvidia"`, else null.      |
| `gpu.vendor`                         | enum               | `none`                | `none` or `nvidia` (`intel`/`amd` reserved, not implemented).                                                     |
| `internalIP`                         | null\|str          | `null`                | Override the IP advertised to Moonlight (`WOLF_INTERNAL_IP`); null = auto-detect (set for NAT/overlay/multi-NIC). |
| `openFirewall`                       | bool               | `false`               | Open the Wolf ports in the firewall.                                                                              |
| `privateCertPath` / `privateKeyPath` | null\|str          | `null`                | TLS cert/key paths (set both or neither).                                                                         |
| `profiles`                           | list               | `[]`                  | Wolf UI profiles (`name`, `apps`, `icon`, `pin`).                                                                 |
| `socketPath`                         | null\|str          | `/run/wolf/wolf.sock` | Host path for the Wolf control socket (used by `wolf-ui`; null to disable).                                       |

### Misc Options

| Option                            | Type              | Default                                                    | Description                                                     |
| --------------------------------- | ----------------- | ---------------------------------------------------------- | --------------------------------------------------------------- |
| `configDir`                       | str               | `/var/lib/wolf/config`                                     | Host dir for config.toml, TLS, paired clients.                  |
| `dataDir`                         | str               | `/var/lib/wolf/data`                                       | Host dir for app state.                                         |
| `defaultRunUid` / `defaultRunGid` | null\|int         | `null`                                                     | UID/GID apps run as (`WOLF_DEFAULT_RUN_*`; null = Wolf's 1000). |
| `extraConfig`                     | attrs             | `{}`                                                       | Extra top-level `config.toml` fields.                           |
| `extraEnvironment`                | attrs of str      | `{}`                                                       | Extra Wolf-server environment variables.                        |
| `extraOptions`                    | list of str       | `[]`                                                       | Extra backend (podman/docker) flags.                            |
| `extraVolumes`                    | list of str       | `[]`                                                       | Extra Wolf container volume mounts.                             |
| `gpu.extraLibs`                   | list of pkg       | `[]`                                                       | Extra driver-volume libs (`cuda_nvrtc` is always included).     |
| `gpu.renderNode`                  | str               | `/dev/dri/renderD128`                                      | `WOLF_RENDER_NODE`.                                             |
| `gpu.useCDI`                      | bool              | `true`                                                     | NVIDIA via CDI vs enumerating `/dev/nvidia*`.                   |
| `hostname`                        | str               | host name                                                  | Display name in Moonlight's host list.                          |
| `logLevel`                        | enum              | `INFO`                                                     | `WOLF_LOG_LEVEL` (`ERROR`…`TRACE`).                             |
| `moonlightApps`                   | list              | `[ wolf-ui ]`                                              | Apps shown on the Moonlight entry screen.                       |
| `ports.audioUDP`                  | port              | `48200`                                                    | Audio RTP port, opened when `openFirewall`.                     |
| `ports.controlUDP`                | port              | `47999`                                                    | Control (input/stream) port, opened when `openFirewall`.        |
| `ports.httpsTCP`                  | port              | `47984`                                                    | HTTPS control port (Moonlight), opened when `openFirewall`.     |
| `ports.httpTCP`                   | port              | `47989`                                                    | HTTP pairing port, opened when `openFirewall`.                  |
| `ports.rtspTCP`                   | port              | `48010`                                                    | RTSP stream-negotiation port, opened when `openFirewall`.       |
| `ports.videoUDP`                  | port              | `48100`                                                    | Video RTP port, opened when `openFirewall`.                     |
| `preserveKeys`                    | list of str       | `[ paired_clients config_version support_hevc gstreamer ]` | config.toml keys preserved across deploys (see below).          |
| `pulseImage`                      | str               | pinned                                                     | PulseAudio sidecar image (`WOLF_PULSE_IMAGE`).                  |
| `storageDriver`                   | `overlay`\|`vfs`  | `overlay`                                                  | podman storage driver (use `vfs` on virtiofs/FUSE).             |
| `stopContainerOnExit`             | bool              | `true`                                                     | Stop/remove app containers when a client disconnects.           |
| `supportHevc`                     | null\|bool        | `null`                                                     | config.toml `support_hevc` (null = leave to Wolf).              |
| `wolfTag`                         | `stable`\|`alpha` | `stable`                                                   | Which pinned Wolf image tag to run.                             |

### config.toml Options

The module generates Wolf's `config.toml` — `uuid`, `hostname`, and `profiles`
(plus `support_hevc` when `supportHevc` is set). For any other top-level field
in the
[Wolf config reference](https://games-on-whales.github.io/wolf/stable/user/configuration.html),
use `extraConfig`:

```nix
{
  services.wolf.extraConfig = {
    support_hevc = false; # or use the dedicated `supportHevc` option
  };
}
```

`config.toml` also holds **runtime-managed, mutable state** that Wolf rewrites
itself: `paired_clients`, `gstreamer` (the auto-detected encoder pipeline), and
`config_version`. These keys are listed in `preserveKeys` and are **preserved**
from the live file on every deploy, so a redeploy never clobbers them — e.g.
your paired Moonlight clients and hardware-detected encoders survive. Setting a
preserved key via `extraConfig` (or `supportHevc`) drops it from the preserved
set so your declarative value wins instead.

### Environment Variables

Common Wolf-server
[environment variables](https://games-on-whales.github.io/wolf/stable/user/configuration.html)
are first-class options (`logLevel` → `WOLF_LOG_LEVEL`, `pulseImage`,
`stopContainerOnExit`, `gpu.renderNode`, `defaultRun{Uid,Gid}`, …). Set any
other with `extraEnvironment`:

```nix
{
  services.wolf.extraEnvironment = {
    GST_DEBUG = "3";
    RUST_BACKTRACE = "full";
  };
}
```

Per-app environment (`RUN_SWAY`, `PROTON_LOG`, `XKB_DEFAULT_LAYOUT`, …) is set on
each app via the catalog / `extraApps` / `appExtraEnv`, not here.

## Updating pinned digests

Wolf ships as a moving Docker tag (`ghcr.io/games-on-whales/wolf:stable`), and
it launches a fleet of companion/app containers (pulseaudio, steam, firefox,
…) that are likewise published as moving tags. This flake records the current
digest of each in
[`generated/containers.json`](./generated/containers.json) so deploys are
reproducible, and a nightly CI job refreshes those digests.

`generated/containers.json` is regenerated from the live registry with
[`update-containers.sh`](./update-containers.sh). The set of images/tags to pin
is **derived from the catalog** (the `trackedImages` flake output = every
`imageRef` in [`apps.nix`](./apps.nix) plus a small core list in
[`flake.nix`](./flake.nix)), so adding an app needs no second list. The
`update-containers` package embeds that list and passes it to the script, so:

```bash
nix run .#update-containers     # from this directory
```

A nightly GitHub Actions workflow runs this and commits any digest changes to
`main`. The flake only consumes the `stable` Wolf tag; `buildcache`/`alpha` are
tracked for reference (`buildcache` is a CI layer-cache manifest, not a runnable
release).
