# wolf-nvidia-vol — Build the Games on Whales NVIDIA driver volume as a Nix
# store path. Replaces the runtime `podman build` of the Wolf Dockerfile by
# running the NVIDIA .run installer inside a QEMU VM at build time.
#
# The output is a directory with the same /usr/nvidia layout that Wolf and
# Wolf child containers expect. Mount it as a bind mount instead of a named
# Docker/Podman volume.
#
# Requires KVM on the builder (the VM runs the NVIDIA installer).
{
  description = "Games on Whales NVIDIA driver volume as a Nix derivation";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
    in
    {
      lib.mkWolfNvidiaVol =
        {
          pkgs,
          # The NVIDIA driver package (e.g. config.hardware.nvidia.package).
          # Must have .src (the .run file) and .version attributes.
          nvidiaPackage,
          # Optional: extra packages to copy into the volume's lib/ directory.
          # Useful for libraries not included in the .run installer, e.g.
          # pkgs.cudaPackages.cuda_nvrtc.lib for libnvrtc.
          extraLibs ? [ ],
        }:
        assert lib.assertMsg (pkgs.stdenv.hostPlatform.isx86_64
        ) "wolf-nvidia-vol: only x86_64-linux is supported (NVIDIA desktop drivers are x86_64 only)";
        assert lib.assertMsg (
          nvidiaPackage ? src
        ) "wolf-nvidia-vol: nvidiaPackage must have a .src attribute pointing to the NVIDIA .run installer";
        assert lib.assertMsg (
          nvidiaPackage ? version
        ) "wolf-nvidia-vol: nvidiaPackage must have a .version attribute";
        let
          nvVersion = nvidiaPackage.version;
        in
        pkgs.vmTools.runInLinuxVM (
          pkgs.stdenv.mkDerivation {
            name = "wolf-nvidia-driver-vol-${nvVersion}";

            nativeBuildInputs = with pkgs; [
              pkg-config
              libglvnd
              zstd
              util-linux
              kmod
            ];

            # Don't patch RPATHs or strip — these .so files run inside
            # containers with LD_LIBRARY_PATH=/usr/nvidia/lib
            dontPatchELF = true;
            dontStrip = true;

            memSize = 4096;
            diskSize = 8192;

            buildCommand = ''
              # The .run self-extractor and nvidia-installer expect an FHS layout.
              # Set up the minimal FHS environment in the VM.
              mkdir -p /lib64 /var/log /bin /sbin /usr/bin

              # Dynamic linker for the embedded zstd and nvidia-installer binaries
              ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2

              # Required system utilities (nvidia-installer searches FHS paths)
              ln -s ${pkgs.glibc.bin}/bin/ldconfig /sbin/ldconfig
              ln -s ${pkgs.coreutils}/bin/tail /usr/bin/tail
              ln -s ${pkgs.gnugrep}/bin/grep /bin/grep
              ln -s ${pkgs.util-linux}/bin/dmesg /bin/dmesg
              ln -s ${pkgs.kmod}/bin/modprobe /sbin/modprobe
              ln -s ${pkgs.kmod}/bin/lsmod /sbin/lsmod
              ln -s ${pkgs.kmod}/bin/rmmod /sbin/rmmod
              ln -s ${pkgs.kmod}/bin/depmod /sbin/depmod

              # Run the NVIDIA installer with the same flags as the Wolf Dockerfile
              sh ${nvidiaPackage.src} --silent -z \
                --skip-depmod --skip-module-unload \
                --no-nvidia-modprobe --no-kernel-modules --no-kernel-module-source \
                --opengl-prefix=$out --wine-prefix=$out --utility-prefix=$out \
                --utility-libdir=lib --compat32-prefix=$out --compat32-libdir=lib32 \
                --egl-external-platform-config-path=$out/share/egl/egl_external_platform.d \
                --glvnd-egl-config-path=$out/share/glvnd/egl_vendor.d \
                --no-distro-scripts

              # Copy Vulkan ICD to the location Wolf's 30-nvidia.sh expects
              mkdir -p $out/share/vulkan/icd.d
              cp /etc/vulkan/icd.d/nvidia_icd.json $out/share/vulkan/icd.d/ 2>/dev/null || true

              # Copy extra libraries (e.g. libnvrtc from CUDA toolkit)
              ${lib.optionalString (extraLibs != [ ]) ''
                for lib in ${builtins.concatStringsSep " " (map (l: "${l}/lib/*") extraLibs)}; do
                  cp -d "$lib" $out/lib/ 2>/dev/null || true
                done
              ''}

              # Verify the build produced usable output
              if [ ! -f "$out/lib/libcuda.so" ]; then
                echo "ERROR: NVIDIA installer failed — libcuda.so not found"
                ls -la "$out/lib/" 2>&1 || true
                exit 1
              fi

              # Convert absolute symlinks to relative. The installer creates
              # cross-directory symlinks with absolute nix store paths, which
              # break when the volume is mounted at /usr/nvidia in containers.
              fixupPhase
            '';
          }
        );
    };
}
