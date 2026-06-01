# Wolf (Games on Whales) NixOS module.
#
# Provided by the flake as `nixosModules.default`. Closes over the
# `wolf-nvidia-vol` flake input; reads digest pins from ./generated/containers.json
# and the built-in catalog from ./apps.nix. Backend (podman/docker) and GPU
# (nvidia/intel/amd) are options so the module is reusable beyond the reference
# nvidia+podman deployment.
{ wolf-nvidia-vol }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.wolf;

  # Digest pins → "ghcr.io/...@sha256:..." . Fails the build with a clear
  # message if a referenced image/tag isn't in containers.json.
  containers = builtins.fromJSON (builtins.readFile ./generated/containers.json);
  image =
    name: tag:
    let
      img =
        containers.${name}.${tag}
          or (throw "wolf: no pinned digest for ${name}:${tag} in containers.json (run update-containers.sh)");
    in
    "${img.image}@${img.digest}";

  # Built-in app catalog. apps.nix declares images as `imageRef = { name; tag; }`;
  # rewrite each to a digest-pinned `image` for config.toml.
  socketPath' = if cfg.socketPath == null then "/run/wolf/wolf.sock" else cfg.socketPath;
  rawApps = import ./apps.nix { socketPath = socketPath'; };
  builtinAppNames = lib.attrNames rawApps;
  resolveImage =
    app:
    if app ? runner && app.runner ? imageRef then
      app
      // {
        runner = (removeAttrs app.runner [ "imageRef" ]) // {
          image = image app.runner.imageRef.name app.runner.imageRef.tag;
        };
      }
    else
      app;
  builtinApps = lib.mapAttrs (_: resolveImage) rawApps;

  # Append per-app extra env (services.wolf.appExtraEnv) onto the catalog.
  applyExtraEnv =
    name: app:
    let
      extra = cfg.appExtraEnv.${name} or [ ];
    in
    if extra == [ ] then
      app
    else
      app
      // {
        runner = (app.runner or { }) // {
          env = (app.runner.env or [ ]) ++ extra;
        };
      };

  # Consumer apps (extraApps) layered over the built-ins, then extra env applied.
  appCatalog = lib.mapAttrs applyExtraEnv (builtinApps // cfg.extraApps);
  unknownExtraEnv = lib.filter (n: !(lib.elem n builtinAppNames)) (lib.attrNames cfg.appExtraEnv);

  nvidia = cfg.gpu.vendor == "nvidia";
  wolfNvidiaVol =
    if nvidia then
      wolf-nvidia-vol.lib.mkWolfNvidiaVol {
        inherit pkgs;
        nvidiaPackage = cfg.gpu.nvidiaPackage;
        inherit (cfg.gpu) extraLibs;
      }
    else
      null;

  tomlFormat = pkgs.formats.toml { };

  appSubmodule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "App identifier from the catalog (built-in apps.nix or extraApps).";
      };
      prefetch = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          If true, pre-pull this app's container image on boot via the
          `wolf-prefetch-images` systemd unit so the first launch from the Wolf
          UI doesn't have to download it. Non-docker apps are silently skipped.
        '';
      };
    };
  };

  # Resolve a profile's apps into full app definitions from the catalog.
  resolveProfile =
    profile:
    {
      id = profile.name;
      inherit (profile) name;
      apps = map (a: appCatalog.${a.name}) profile.apps;
    }
    // lib.optionalAttrs (profile.icon != null) {
      icon_png_path = "profile-pictures/${profile.name}.png";
    }
    // lib.optionalAttrs (profile.pin != null) {
      inherit (profile) pin;
    };

  # The Moonlight entrypoint profile — apps visible directly in Moonlight.
  moonlightProfile = {
    id = "moonlight-profile-id";
    apps = map (a: appCatalog.${a.name}) cfg.moonlightApps;
  };

  resolvedProfiles = [ moonlightProfile ] ++ map resolveProfile cfg.profiles;

  generatedConfig = {
    inherit (cfg) uuid hostname;
    profiles = resolvedProfiles;
  }
  // lib.optionalAttrs (cfg.supportHevc != null) { support_hevc = cfg.supportHevc; }
  // cfg.extraConfig;

  generatedToml = tomlFormat.generate "wolf-config.toml" generatedConfig;

  # Keys the consumer explicitly generates (supportHevc / extraConfig) must NOT
  # be preserved from the live config, or the merge would clobber them.
  generatedTopKeys =
    lib.optional (cfg.supportHevc != null) "support_hevc" ++ lib.attrNames cfg.extraConfig;
  effectivePreserveKeys = lib.filter (k: !(lib.elem k generatedTopKeys)) cfg.preserveKeys;

  # Build a derivation containing all profile pictures.
  profilesWithIcons = lib.filter (p: p.icon != null) cfg.profiles;
  profilePicsDir = pkgs.runCommand "wolf-profile-pictures" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatMapStringsSep "\n" (p: "cp ${p.icon} $out/${p.name}.png") profilesWithIcons
  );

  pythonWithTomli = pkgs.python3.withPackages (ps: [ ps.tomli-w ]);
  mergeScript = pkgs.writeScript "wolf-merge-config" ''
    #!${pythonWithTomli}/bin/python3
    ${builtins.readFile ./merge-config.py}
  '';

  # Flat list of every app reference across moonlightApps and all profiles.
  allAppRefs = cfg.moonlightApps ++ lib.concatMap (p: p.apps) cfg.profiles;
  allReferencedApps = lib.unique (map (a: a.name) allAppRefs);
  missingApps = lib.filter (name: !lib.hasAttr name appCatalog) allReferencedApps;

  # Union of names marked prefetch=true across all profiles + moonlight.
  prefetchAppNames = lib.unique (map (a: a.name) (lib.filter (a: a.prefetch) allAppRefs));
  prefetchImages = lib.filter (img: img != null) (
    map (name: appCatalog.${name}.runner.image or null) prefetchAppNames
  );

  backend = cfg.backend;
  dockerSocketHost =
    if backend == "podman" then "/run/podman/podman.sock" else "/var/run/docker.sock";
in
{
  options.services.wolf = {
    enable = lib.mkEnableOption "Wolf cloud gaming server";

    backend = lib.mkOption {
      type = lib.types.enum [
        "podman"
        "docker"
      ];
      default = "podman";
      description = "OCI container backend used to run Wolf and its child app containers.";
    };

    storageDriver = lib.mkOption {
      type = lib.types.enum [
        "overlay"
        "vfs"
      ];
      default = "overlay";
      description = "Container storage driver (podman backend). Use 'vfs' when the graphroot is on virtiofs/FUSE.";
    };

    uuid = lib.mkOption {
      type = lib.types.str;
      description = "Stable host identifier. Moonlight uses this to recognize a previously paired host. Changing it forces all clients to re-pair.";
      example = "c0c283f1-5f7b-4467-a21d-472283c249b7";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Display name shown in Moonlight's host list.";
    };

    internalIP = lib.mkOption {
      type = lib.types.str;
      description = "Internal IP address advertised to Moonlight (WOLF_INTERNAL_IP).";
      example = "192.168.0.39";
    };

    openFirewall = lib.mkEnableOption "opening Wolf ports in the firewall";

    wolfTag = lib.mkOption {
      type = lib.types.enum [
        "stable"
        "alpha"
      ];
      default = "stable";
      description = "Which pinned Wolf image tag to run (from containers.json).";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "ERROR"
        "WARNING"
        "INFO"
        "DEBUG"
        "TRACE"
      ];
      default = "INFO";
      description = "Wolf log level (WOLF_LOG_LEVEL).";
    };

    pulseImage = lib.mkOption {
      type = lib.types.str;
      default = image "pulseaudio" "master";
      defaultText = lib.literalExpression ''image "pulseaudio" "master"'';
      description = "PulseAudio sidecar image Wolf starts for audio (WOLF_PULSE_IMAGE). Digest-pinned by default.";
    };

    stopContainerOnExit = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Force-stop/remove child app containers when a client disconnects (WOLF_STOP_CONTAINER_ON_EXIT).";
    };

    supportHevc = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Set the config.toml `support_hevc` flag declaratively (null = leave it to
        Wolf, preserved from the live config). Setting it removes `support_hevc`
        from the preserved keys so this value wins.
      '';
    };

    defaultRunUid = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Default UID apps run as for newly paired clients (WOLF_DEFAULT_RUN_UID). null = Wolf default (1000).";
    };

    defaultRunGid = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Default GID apps run as for newly paired clients (WOLF_DEFAULT_RUN_GID). null = Wolf default (1000).";
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/wolf/config";
      description = "Directory for Wolf config (config.toml, TLS certs, paired clients).";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/wolf/data";
      description = "Directory for Wolf app state (per-profile game data, Steam library).";
    };

    privateCertPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to TLS certificate file (sets WOLF_PRIVATE_CERT_FILE).";
    };

    privateKeyPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to TLS private key file (sets WOLF_PRIVATE_KEY_FILE).";
    };

    socketPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/run/wolf/wolf.sock";
      description = "Path to mount the Wolf unix socket on the host (WOLF_SOCKET_PATH).";
    };

    ports = lib.mkOption {
      description = "Wolf network ports, used to open the firewall when openFirewall is set.";
      default = { };
      type = lib.types.submodule {
        options = {
          httpsTCP = lib.mkOption {
            type = lib.types.port;
            default = 47984;
            description = "HTTPS control port (Moonlight).";
          };
          httpTCP = lib.mkOption {
            type = lib.types.port;
            default = 47989;
            description = "HTTP pairing web UI port.";
          };
          rtspTCP = lib.mkOption {
            type = lib.types.port;
            default = 48010;
            description = "RTSP stream negotiation port.";
          };
          controlUDP = lib.mkOption {
            type = lib.types.port;
            default = 47999;
            description = "Control (input, stream control) port.";
          };
          videoUDP = lib.mkOption {
            type = lib.types.port;
            default = 48100;
            description = "Video RTP port.";
          };
          audioUDP = lib.mkOption {
            type = lib.types.port;
            default = 48200;
            description = "Audio RTP port.";
          };
        };
      };
    };

    gpu = lib.mkOption {
      description = "GPU passthrough configuration for hardware video encoding.";
      default = { };
      type = lib.types.submodule {
        options = {
          vendor = lib.mkOption {
            type = lib.types.enum [
              "nvidia"
              "intel"
              "amd"
              "none"
            ];
            default = "none";
            description = ''
              GPU vendor. "none" (default) adds no GPU-specific config. "nvidia"
              builds and mounts a driver volume via wolf-nvidia-vol and uses CDI.
              "intel"/"amd" are reserved but not yet implemented.
            '';
          };
          nvidiaPackage = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            example = lib.literalExpression "config.hardware.nvidia.package";
            description = "NVIDIA driver package (required when vendor = \"nvidia\"). Must expose .src (the .run installer) and .version.";
          };
          extraLibs = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = "Extra libraries to copy into the NVIDIA driver volume, for libraries a GStreamer element needs that aren't in the driver .run installer. Rarely required.";
          };
          renderNode = lib.mkOption {
            type = lib.types.str;
            default = "/dev/dri/renderD128";
            description = "DRM render node for virtual desktops (WOLF_RENDER_NODE).";
          };
          useCDI = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "For nvidia: pass the GPU via CDI (--device=nvidia.com/gpu=all) instead of enumerating /dev/nvidia* devices.";
          };
        };
      };
    };

    profiles = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Display name in Wolf UI.";
            };
            apps = lib.mkOption {
              type = lib.types.listOf appSubmodule;
              description = "Apps from the catalog to include in this profile (each may opt into prefetch).";
            };
            icon = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to a profile picture PNG (200x266 or 628x888).";
            };
            pin = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.int);
              default = null;
              description = "PIN to protect this profile (array of digits, e.g. [1 2 3 4]).";
            };
          };
        }
      );
      default = [ ];
      description = "User profiles shown in the Wolf UI profile selection screen.";
    };

    moonlightApps = lib.mkOption {
      type = lib.types.listOf appSubmodule;
      default = [ { name = "wolf-ui"; } ];
      description = "Apps for the Moonlight entrypoint profile. Default shows the Launcher (Wolf UI).";
    };

    extraApps = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = ''
        Additional apps to register in the catalog, keyed by app identifier.
        Each value is a TOML-ready attrset matching Wolf's [[profiles.apps]]
        schema (see the built-in apps.nix for examples). Overrides built-in apps
        of the same name.
      '';
      example = lib.literalExpression ''
        {
          mygame = {
            title = "My Game";
            runner = {
              type = "docker";
              name = "MyGame";
              image = "ghcr.io/me/mygame@sha256:...";
            };
          };
        }
      '';
    };

    appExtraEnv = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      description = ''
        Extra environment variables appended to a built-in app's container,
        keyed by app identifier. Each key must name an app from the built-in
        catalog (apps.nix). Use this to tweak a stock app without redefining it;
        to change other fields, override the app via extraApps instead.
      '';
      example = lib.literalExpression ''
        {
          steam = [ "DXVK_CONFIG=dxgi.syncInterval = 0; ..." ];
        }
      '';
    };

    preserveKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "paired_clients"
        "config_version"
        "support_hevc"
        "gstreamer"
      ];
      description = "config.toml keys preserved from the live config during merge (runtime-managed state).";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the Wolf container (escape hatch for any WOLF_*/server env not modelled above, e.g. RUST_BACKTRACE, GST_DEBUG, WOLF_DOCKER_FAKE_UDEV_PATH).";
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra top-level config.toml fields merged into the generated config
        (escape hatch for keys not modelled above, e.g. a custom `gstreamer`
        pipeline). Any key set here overrides the preserved live value.
      '';
      example = lib.literalExpression "{ support_hevc = false; }";
    };

    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra volume mounts appended to the Wolf container.";
    };

    extraOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra backend (podman/docker) flags appended to the Wolf container.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = missingApps == [ ];
        message = "Wolf: unknown app names: ${lib.concatStringsSep ", " missingApps}. Available: ${lib.concatStringsSep ", " (lib.attrNames appCatalog)}";
      }
      {
        # nvidia and none (no dedicated GPU config) are supported; intel/amd are
        # reserved in the enum but not yet implemented/tested.
        assertion =
          !(lib.elem cfg.gpu.vendor [
            "intel"
            "amd"
          ]);
        message = "Wolf: services.wolf.gpu.vendor = \"${cfg.gpu.vendor}\" is not yet supported (use \"nvidia\" or \"none\").";
      }
      {
        assertion = nvidia -> cfg.gpu.nvidiaPackage != null;
        message = "Wolf: services.wolf.gpu.nvidiaPackage must be set when gpu.vendor = \"nvidia\" (e.g. config.hardware.nvidia.package).";
      }
      {
        assertion = (cfg.privateCertPath == null) == (cfg.privateKeyPath == null);
        message = "Wolf: set both services.wolf.privateCertPath and privateKeyPath, or neither.";
      }
      {
        # wolf-ui mounts the Wolf control socket; without socketPath the mount
        # is malformed and the launcher can't reach Wolf.
        assertion = (!(lib.elem "wolf-ui" allReferencedApps)) || cfg.socketPath != null;
        message = "Wolf: the wolf-ui app requires services.wolf.socketPath to be set.";
      }
      {
        assertion = (map (p: p.name) cfg.profiles) == lib.unique (map (p: p.name) cfg.profiles);
        message = "Wolf: profile names must be unique.";
      }
      {
        assertion = unknownExtraEnv == [ ];
        message = "Wolf: services.wolf.appExtraEnv keys must be built-in apps: ${lib.concatStringsSep ", " unknownExtraEnv} not in ${lib.concatStringsSep ", " builtinAppNames}.";
      }
    ];

    virtualisation.oci-containers.backend = cfg.backend;

    virtualisation.podman = lib.mkIf (backend == "podman") {
      enable = true;
      autoPrune.enable = lib.mkDefault true;
      defaultNetwork.settings = {
        dns_enabled = lib.mkDefault true;
        dns = lib.mkDefault [
          "9.9.9.9"
          "1.1.1.1"
        ];
      };
    };
    virtualisation.containers.storage.settings.storage.driver = lib.mkIf (
      backend == "podman"
    ) cfg.storageDriver;
    virtualisation.docker.enable = lib.mkIf (backend == "docker") true;

    # nvidia + CDI requires the container toolkit to generate the CDI spec.
    hardware.nvidia-container-toolkit.enable = lib.mkIf (nvidia && cfg.gpu.useCDI) (lib.mkDefault true);

    boot.kernelModules = [ "uhid" ];

    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
      KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="input", MODE="0660", ENV{ID_SEAT}="seat9"
      SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
      SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
      SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", MODE="0660", ENV{ID_SEAT}="seat9"
      SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
    '';

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        cfg.ports.httpsTCP
        cfg.ports.httpTCP
        cfg.ports.rtspTCP
      ];
      allowedUDPPorts = [
        cfg.ports.controlUDP
        cfg.ports.videoUDP
        cfg.ports.audioUDP
      ];
    };

    # Wolf uses /tmp/sockets as XDG_RUNTIME_DIR for its Unix socket, shared with
    # child containers via bind mount.
    systemd.tmpfiles.rules = [
      "d /tmp/sockets 0755 root root -"
    ]
    ++ lib.optional (cfg.socketPath != null) "d ${dirOf cfg.socketPath} 0755 root root -";

    # Pre-pull child container images so they're cached before Wolf launches
    # them. Runs in parallel with the Wolf unit; lazy-pulled apps are unaffected.
    systemd.services.wolf-prefetch-images = lib.mkIf (prefetchImages != [ ]) {
      description = "Pre-pull Wolf app container images";
      after = [
        "network-online.target"
        "${backend}.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      restartTriggers = prefetchImages;
      script =
        let
          runtime = "${config.virtualisation.${backend}.package}/bin/${backend}";
        in
        lib.concatMapStringsSep "\n" (img: ''
          echo "Pulling ${img}..."
          ${runtime} pull "${img}" || echo "WARNING: failed to pull ${img}" >&2
        '') prefetchImages;
    };

    systemd.services."${backend}-wolf".serviceConfig.ExecStartPre =
      let
        runtime = "${config.virtualisation.${backend}.package}/bin/${backend}";
        preserveArgs = lib.escapeShellArgs effectivePreserveKeys;
      in
      # Merge nix-generated config with live config.toml, then clean up stale
      # child containers.
      (lib.optional (
        cfg.profiles != [ ]
      ) "${mergeScript} ${generatedToml} ${cfg.configDir}/config.toml ${preserveArgs}")
      ++ [
        # Fix /tmp/sockets ownership — must be root for Wolf/PulseAudio to work.
        "+${pkgs.bash}/bin/bash -c 'if [ \"$(stat -c %u /tmp/sockets)\" != \"0\" ]; then echo \"WARNING: /tmp/sockets had wrong owner ($(stat -c %U /tmp/sockets)), fixing to root\" >&2; chown root:root /tmp/sockets && chmod 0755 /tmp/sockets; fi'"
        # Clean up stale Wolf child containers before each start.
        "-${pkgs.bash}/bin/bash -c '${runtime} rm -f $(${runtime} ps -a --filter name=Wolf -q) 2>/dev/null || true'"
      ];

    virtualisation.oci-containers.containers.wolf = {
      image = image "wolf" cfg.wolfTag;
      extraOptions = [
        "--network=host"
        "--privileged"
        "--ipc=host"
        ''--device-cgroup-rule="c 13:* rmw"''
        "--volume=${dockerSocketHost}:/var/run/docker.sock:ro"
        "--volume=/dev:/dev:rw"
        "--volume=/run/udev:/run/udev:rw"
        "--volume=/tmp/sockets:/tmp/sockets:rw"
      ]
      ++ lib.optionals nvidia (
        if cfg.gpu.useCDI then
          [ "--device=nvidia.com/gpu=all" ]
        else
          [
            "--device=/dev/nvidia0"
            "--device=/dev/nvidiactl"
            "--device=/dev/nvidia-modeset"
            "--device=/dev/nvidia-uvm"
            "--device=/dev/nvidia-uvm-tools"
          ]
      )
      ++ lib.optional (
        cfg.socketPath != null
      ) "--volume=${dirOf cfg.socketPath}:${dirOf cfg.socketPath}:rw"
      ++ cfg.extraOptions;
      volumes = [
        "${cfg.configDir}:/etc/wolf/cfg"
        "${cfg.dataDir}:/etc/wolf"
      ]
      ++ lib.optional nvidia "${wolfNvidiaVol}:/usr/nvidia:ro"
      ++ lib.optional (profilesWithIcons != [ ]) "${profilePicsDir}:/etc/wolf/profile-pictures:ro"
      ++ cfg.extraVolumes;
      environment = {
        WOLF_INTERNAL_IP = cfg.internalIP;
        WOLF_RENDER_NODE = cfg.gpu.renderNode;
        WOLF_LOG_LEVEL = cfg.logLevel;
        WOLF_STOP_CONTAINER_ON_EXIT = if cfg.stopContainerOnExit then "TRUE" else "FALSE";
        WOLF_PULSE_IMAGE = cfg.pulseImage;
        XDG_RUNTIME_DIR = "/tmp/sockets";
        HOST_APPS_STATE_FOLDER = "/etc/wolf";
      }
      // lib.optionalAttrs nvidia {
        # Wolf passes the driver volume to child containers via the Binds API —
        # a host path works in place of a named volume.
        NVIDIA_DRIVER_VOLUME_NAME = "${wolfNvidiaVol}";
        NVIDIA_VISIBLE_DEVICES = "all";
        NVIDIA_DRIVER_CAPABILITIES = "all";
        LD_LIBRARY_PATH = "/usr/nvidia/lib:/usr/nvidia/lib64";
      }
      // lib.optionalAttrs (cfg.privateCertPath != null) {
        WOLF_PRIVATE_CERT_FILE = cfg.privateCertPath;
      }
      // lib.optionalAttrs (cfg.privateKeyPath != null) {
        WOLF_PRIVATE_KEY_FILE = cfg.privateKeyPath;
      }
      // lib.optionalAttrs (cfg.socketPath != null) {
        WOLF_SOCKET_PATH = cfg.socketPath;
      }
      // lib.optionalAttrs (cfg.defaultRunUid != null) {
        WOLF_DEFAULT_RUN_UID = toString cfg.defaultRunUid;
      }
      // lib.optionalAttrs (cfg.defaultRunGid != null) {
        WOLF_DEFAULT_RUN_GID = toString cfg.defaultRunGid;
      }
      // cfg.extraEnvironment;
    };
  };
}
