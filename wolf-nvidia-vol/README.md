# wolf-nvidia-vol

Build the [Games on Whales](https://games-on-whales.github.io) NVIDIA driver volume as a Nix store path. Replaces the manual podman/docker volume creation from the "Nvidia (Manual)" section of [the Quickstart documentation](https://Wolf.github.io/wolf/stable/user/quickstart.html).

## How to use it

Add to your flake.nix:

```nix
{
  inputs = {
    wolf-nvidia-vol = {
      url = "github:altano/flakes?dir=wolf-nvidia-vol";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

Add to your Wolf service:

```nix
{
  config,
  pkgs,
  inputs,
  ...
}:
let
  wolfNvidiaVol = inputs.wolf-nvidia-vol.lib.mkWolfNvidiaVol {
    inherit pkgs;
    nvidiaPackage = config.hardware.nvidia.package;
    # libnvrtc is required by GStreamer's cudaconvertscale element for
    # NVENC hardware encoding. It's not included in the driver .run file.
    extraLibs = [ pkgs.cudaPackages.cuda_nvrtc.lib ];
  };
in
{
  virtualisation.oci-containers.containers.wolf = {
    volumes = [
      "${wolfNvidiaVol}:/usr/nvidia:ro"
    ];
    environment = {
      # Wolf passes this to child containers via Binds API — host paths work
      NVIDIA_DRIVER_VOLUME_NAME = "${wolfNvidiaVol}";
    };
  };
}
```

## Overriding the NVIDIA driver version

The `nvidiaPackage` parameter has no default — you must pass it explicitly. If your nixpkgs doesn't have the driver version you need, use `mkDriver` to pin a specific version.

You can extract the hashes from a nixpkgs that has the version you want (e.g., nixos-unstable):

```bash
nix eval --impure --expr '
  let pkgs = import (fetchTarball
    "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz"
  ) { system = "x86_64-linux"; config.allowUnfree = true; };
  drv = pkgs.linuxPackages.nvidiaPackages.production;
  in { inherit (drv) version; sha256 = drv.src.outputHash;
       open = drv.open.src.outputHash;
       settings = drv.settings.src.outputHash;
       persistenced = drv.persistenced.src.outputHash; }
' --json
```

Then pass them to `mkDriver` (see the [NixOS wiki](https://nixos.wiki/wiki/Nvidia#Running_Specific_NVIDIA_Driver_Versions) for more details):

```nix
{
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
    version = "580.142";
    sha256_64bit = "sha256-IJFfzz/+icNVDPk7YKBKKFRTFQ2S4kaOGRGkNiBEdWM=";
    openSha256 = "sha256-v968LbRqy8jB9+yHy9ceP2TDdgyqfDQ6P41NsCoM2AY=";
    settingsSha256 = "sha256-BnrIlj5AvXTfqg/qcBt2OS9bTDDZd3uhf5jqOtTMTQM=";
    persistencedSha256 = "sha256-il403KPFAnDbB+dITnBGljhpsUPjZwmLjGt8iPKuBqw=";
  };
}
```

This builds the driver against your system's kernel, avoiding version mismatches. The `wolfNvidiaVol` derivation picks up the override since it references `config.hardware.nvidia.package`.

## How it works

Runs the NVIDIA `.run` installer inside a QEMU VM at build time. The output is a directory with the same `/usr/nvidia` layout that Wolf child containers expect. Mount it as a bind mount instead of a named Docker/Podman volume.

## Requirements

- KVM on the builder (the VM runs the NVIDIA installer)
- x86_64-linux (NVIDIA desktop drivers are x86_64 only)
