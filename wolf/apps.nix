# Wolf app catalog — standard Games on Whales applications.
#
# Each entry is a TOML-ready attrset matching Wolf's [[profiles.apps]] schema;
# keys are app identifiers referenced from profiles. Docker images are given as
# `imageRef = { name; tag; }` (structured, not a resolved string) so the flake
# can both (a) pin the digest from generated/containers.json and (b) enumerate
# the set of images to track — with no second hand-maintained list. The module
# rewrites `imageRef` to a digest-pinned `image` before generating config.toml.
#
# This catalog is the default value of `services.wolf.apps`. Customize a
# built-in app with `services.wolf.appExtraEnv` (append env) or override it
# wholesale via `services.wolf.extraApps`; see the README.
{
  # socketPath: where the Wolf control socket lives (services.wolf.socketPath).
  socketPath,
}:
{
  # Wolf UI — the main launcher that shows profile selection and app management
  wolf-ui = {
    title = "Launcher"; # Wolf UI
    icon_png_path = "https://raw.githubusercontent.com/games-on-whales/wolf-ui/refs/heads/main/src/Icons/wolf_ui_icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "Wolf-UI";
      imageRef = {
        name = "wolf-ui";
        tag = "main";
      };
      mounts = [ "${socketPath}:${socketPath}" ];
      env = [
        "GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/* /dev/nvidia*"
        "WOLF_SOCKET_PATH=${socketPath}"
        "WOLF_UI_AUTOUPDATE=False"
        "LOGLEVEL=INFO"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          CapAdd = [
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
            "SYS_ADMIN"
            "SYS_NICE"
          ];
          Privileged = false;
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  firefox = {
    title = "Firefox";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/firefox/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfFirefox";
      imageRef = {
        name = "firefox";
        tag = "edge";
      };
      mounts = [ ];
      env = [
        "RUN_SWAY=1"
        "MOZ_ENABLE_WAYLAND=1"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          Privileged = false;
          CapAdd = [
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
          ];
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  retroarch = {
    title = "RetroArch";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/retroarch/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfRetroarch";
      imageRef = {
        name = "retroarch";
        tag = "edge";
      };
      mounts = [ ];
      env = [
        "RUN_SWAY=true"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          CapAdd = [
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
            "SYS_ADMIN"
            "SYS_NICE"
          ];
          Privileged = false;
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  steam = {
    title = "Steam";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/steam/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfSteam";
      imageRef = {
        name = "steam";
        tag = "edge";
      };
      mounts = [ ];
      env = [
        "PROTON_LOG=1"
        "RUN_SWAY=true"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          CapAdd = [
            "SYS_ADMIN"
            "SYS_NICE"
            "SYS_PTRACE"
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
          ];
          SecurityOpt = [
            "seccomp=unconfined"
            "apparmor=unconfined"
          ];
          Ulimits = [
            {
              Name = "nofile";
              Hard = 10240;
              Soft = 10240;
            }
          ];
          Privileged = false;
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  pegasus = {
    title = "Pegasus";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/pegasus/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfPegasus";
      imageRef = {
        name = "pegasus";
        tag = "edge";
      };
      mounts = [ ];
      env = [
        "RUN_SWAY=1"
        "GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/* /dev/nvidia*"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          CapAdd = [
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
            "SYS_ADMIN"
            "SYS_NICE"
          ];
          Privileged = false;
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  lutris = {
    title = "Lutris";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/lutris/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfLutris";
      imageRef = {
        name = "lutris";
        tag = "edge";
      };
      mounts = [ "lutris:/var/lutris/:rw" ];
      env = [
        "RUN_SWAY=1"
        "GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/* /dev/nvidia* /var/lutris/"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          CapAdd = [
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
            "SYS_ADMIN"
            "SYS_NICE"
          ];
          Privileged = false;
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  prismlauncher = {
    title = "Prismlauncher";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/prismlauncher/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "Prismlauncher";
      imageRef = {
        name = "prismlauncher";
        tag = "edge";
      };
      mounts = [ ];
      env = [
        "RUN_SWAY=1"
        "GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/* /dev/nvidia* /var/lutris/"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          CapAdd = [
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
            "SYS_ADMIN"
            "SYS_NICE"
          ];
          Privileged = false;
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  desktop = {
    title = "Desktop (xfce)";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/xfce/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfXFCE";
      imageRef = {
        name = "xfce";
        tag = "edge";
      };
      mounts = [ ];
      env = [
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          Privileged = false;
          CapAdd = [
            "SYS_ADMIN"
            "SYS_NICE"
            "SYS_PTRACE"
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
          ];
          SecurityOpt = [
            "seccomp=unconfined"
            "apparmor=unconfined"
          ];
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  emulationstation = {
    title = "EmulationStation";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/es-de/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfES-DE";
      imageRef = {
        name = "es-de";
        tag = "edge";
      };
      mounts = [ ];
      env = [
        "RUN_SWAY=1"
        "MOZ_ENABLE_WAYLAND=1"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          Privileged = false;
          CapAdd = [
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
          ];
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };

  test-ball = {
    title = "Test ball";
    icon_png_path = "https://raw.githubusercontent.com/games-on-whales/wolf/refs/heads/stable/docs/images/test_ball_icon.png";
    start_audio_server = false;
    start_virtual_compositor = false;
    runner = {
      type = "process";
      run_cmd = ''sh -c "while :; do echo 'running...'; sleep 10; done"'';
    };
    audio = {
      source = "audiotestsrc wave=ticks is-live=true";
    };
    video = {
      source = ''
        videotestsrc pattern=ball flip=true is-live=true !
        video/x-raw, framerate={fps}/1'';
    };
  };

  kodi = {
    title = "Kodi";
    icon_png_path = "https://games-on-whales.github.io/wildlife/apps/kodi/assets/icon.png";
    start_virtual_compositor = true;
    runner = {
      type = "docker";
      name = "WolfKodi";
      imageRef = {
        name = "kodi";
        tag = "edge";
      };
      mounts = [ ];
      env = [
        "RUN_SWAY=true"
        "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"
      ];
      devices = [ ];
      ports = [ ];
      base_create_json = builtins.toJSON {
        HostConfig = {
          IpcMode = "host";
          Privileged = false;
          CapAdd = [
            "NET_RAW"
            "MKNOD"
            "NET_ADMIN"
          ];
          DeviceCgroupRules = [
            "c 13:* rmw"
            "c 244:* rmw"
          ];
        };
      };
    };
  };
}
