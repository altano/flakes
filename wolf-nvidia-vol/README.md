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

## How it works

Runs the NVIDIA `.run` installer inside a QEMU VM at build time. The output is a directory with the same `/usr/nvidia` layout that Wolf child containers expect. Mount it as a bind mount instead of a named Docker/Podman volume.

## Requirements

- KVM on the builder (the VM runs the NVIDIA installer)
- x86_64-linux (NVIDIA desktop drivers are x86_64 only)
