# Keeps a `claude remote-control` server running in every project directory
# under the configured roots, so a session in any of them can be picked up
# from claude.ai/code or the Claude mobile app without anyone being logged in.
#
# Four units make that up, all of them the user's own:
#
#   claude-rc@<dir>     one server per directory, restarted on failure and
#                       left in `failed` once it has proved it cannot run.
#   claude-rc-scan      starts an instance for every directory under the
#                       project roots and stops the ones whose directory has
#                       gone. Runs on a timer and whenever a root gains or
#                       loses an entry.
#   claude-rc-login     fails while the CLI is logged out, which is the one
#                       fault nothing else here reports.
#
# Nothing runs as root, so whatever watches user units for this account sees
# every failure above.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.claude-remote-control;
  claudeBin = lib.getExe cfg.package;

  # ExecStart for one instance. A wrapper rather than a bare command line
  # because the session name is derived from the directory, which a systemd
  # specifier cannot do.
  runner = pkgs.writeShellApplication {
    name = "claude-rc-run";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.bash
      pkgs.nettools
    ];
    text = ''
      dir=$1
      cd "$dir"

      # Sessions spawned from the app run shell commands, and a unit inherits
      # none of a login shell's PATH. Without these the session sees only what
      # this wrapper declares, so git, nix and anything installed into the
      # profile are missing.
      export PATH="$HOME/.nix-profile/bin:/run/wrappers/bin:/run/current-system/sw/bin:$PATH"

      # Passed as an environment variable rather than
      # --remote-control-session-name-prefix so that an upstream rename leaves
      # the sessions less well labelled instead of killing the unit. The
      # default prefix is the hostname alone, which would give every instance
      # on this machine the same name in the app.
      project=$(basename "$dir")
      prefix="$(hostname)/$project"
      export CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX="$prefix"
      exec ${claudeBin} remote-control ${lib.escapeShellArgs cfg.extraArgs}
    '';
  };

  # `claude remote-control` exits immediately in a directory whose workspace
  # trust has not been accepted, and trust can only be accepted from a
  # terminal, so nothing here would ever start in a project nobody had already
  # opened by hand.
  #
  # Trust is inherited: the CLI checks the current directory's entry and then
  # walks up to /, so one entry per project root covers every project beneath
  # it, including ones created later. That is why this writes the roots rather
  # than each project directory, which would mean rewriting the file every
  # time one appeared.
  #
  # A repository cloned into one of those roots therefore has its hooks,
  # settings and MCP servers trusted without anyone being asked.
  truster = pkgs.writeShellApplication {
    name = "claude-rc-trust";
    bashOptions = [
      "pipefail"
      "nounset"
    ];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      cfg=$HOME/.claude.json
      roots=${lib.escapeShellArg (builtins.toJSON cfg.projectDirs)}

      # An absent file means the CLI has never run, which also means there is
      # no login and nothing would start. Creating one here would race the
      # CLI's own first-run initialisation.
      [ -s "$cfg" ] || exit 0
      jq -e . "$cfg" >/dev/null 2>&1 ||
        { echo "$cfg is not valid JSON, leaving workspace trust alone"; exit 0; }

      # Write only when a root is missing, which happens on the first scan
      # after a root appears and never again. The CLI owns this file and
      # rewrites it often, so a read-modify-write here can discard whatever it
      # wrote in the same moment. Writing rarely makes that unlikely.
      jq -e --argjson roots "$roots" \
        '. as $c | all($roots[]; $c.projects[.].hasTrustDialogAccepted == true)' \
        "$cfg" >/dev/null && exit 0

      tmp=$(mktemp "$cfg.claude-rc.XXXXXX")
      if jq --argjson roots "$roots" \
           'reduce $roots[] as $r (.; .projects[$r].hasTrustDialogAccepted = true)' \
           "$cfg" > "$tmp"; then
        chmod --reference="$cfg" "$tmp"
        mv "$tmp" "$cfg"
      else
        rm -f "$tmp"
        echo "could not write workspace trust to $cfg"
        exit 1
      fi
    '';
  };

  scanner = pkgs.writeShellApplication {
    name = "claude-rc-scan";
    # No errexit: a scan that stops halfway would leave the previous run's
    # result in place. Every step below guards its own failure instead.
    bashOptions = [
      "pipefail"
      "nounset"
    ];
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      state="$XDG_RUNTIME_DIR/claude-rc"
      mkdir -p "$state"

      # Ask the CLI rather than looking for a credentials file, which can be
      # present with an expired token in it. Anything that is not JSON saying
      # true counts as logged out, which also covers the CLI failing to run.
      #
      # claude-rc-login reads this marker and nothing else does. It carries one
      # bit: present means the CLI answered that it is logged in.
      logged_in=no
      auth=$(${claudeBin} auth status --json 2>/dev/null)
      if printf '%s' "$auth" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
        logged_in=yes
        touch "$state/logged-in"
      else
        rm -f "$state/logged-in"
      fi

      ${lib.optionalString cfg.acceptWorkspaceTrust ''
        # Runs before any instance is started, because a server in an
        # untrusted directory exits immediately.
        ${lib.getExe truster} || echo "workspace trust was not written" >&2
      ''}

      # Every immediate subdirectory of every project root gets a server.
      # Dotted entries are skipped because the glob does not match them.
      #
      # Written to a file rather than kept in a variable so that someone
      # debugging on the machine can see what the last scan decided.
      roots=(${lib.escapeShellArgs cfg.projectDirs})
      for root in "''${roots[@]}"; do
        [ -d "$root" ] || continue
        for dir in "$root"/*/; do
          dir=''${dir%/}
          [ -d "$dir" ] || continue
          printf 'claude-rc@%s.service\n' "$(systemd-escape --path "$dir")"
        done
      done > "$state/wanted.new"
      mv "$state/wanted.new" "$state/wanted"

      # Stop instances whose directory has gone, or whose root is no longer
      # configured. `list-units --all` sees loaded units only, which is exactly
      # the set that can still be running.
      for unit in $(systemctl --user list-units --all --plain --no-legend 'claude-rc@*.service' | awk '{print $1}'); do
        grep -qxF "$unit" "$state/wanted" && continue
        systemctl --user stop "$unit"
        # Stopping a failed unit leaves it failed and loaded, so it would come
        # back from list-units on every scan and be stopped again.
        systemctl --user reset-failed "$unit" 2>/dev/null || true
      done

      # Nothing is started while logged out. Every instance would fail within
      # seconds and systemd would restart each one until it gave up, which is a
      # process spawned every 30 seconds on a machine that cannot do any work.
      # claude-rc-login reports the logged-out state instead.
      [ "$logged_in" = yes ] || exit 0

      while read -r unit; do
        [ -n "$unit" ] || continue
        systemctl --user is-active --quiet "$unit" && continue
        # Clears an earlier failure and a unit that has hit its start limit,
        # either of which makes `start` do nothing.
        systemctl --user reset-failed "$unit" 2>/dev/null || true
        systemctl --user start --no-block "$unit" || echo "could not start $unit" >&2
      done < "$state/wanted"
    '';
  };
in
{
  options.services.claude-remote-control = {
    enable = lib.mkEnableOption "a persistent Claude Code Remote Control server per project directory";

    projectDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Absolute paths whose immediate subdirectories are projects. A root that
        does not exist is skipped, so listing one that has yet to be created is
        fine.

        Only one level down is considered, and dotted entries are ignored.
      '';
      example = [ "/home/alan/src" ];
    };

    acceptWorkspaceTrust = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Accept Claude Code's workspace trust for every path in `projectDirs`.

        Trust is inherited, so one entry per root covers every project beneath
        it, including ones created later. A repository cloned into a root
        therefore has its hooks, settings and MCP servers trusted without
        anyone being asked, which is why this is off by default.

        Leaving it off limits the servers to projects whose trust has already
        been accepted from a terminal. An instance in any other directory
        exits at once and its unit ends up `failed`.
      '';
    };

    scanIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        How often the scanner runs, and so how long it can take to notice a
        login: only the CLI reports login state and nothing signals when it
        changes.

        A project directory being created or removed is noticed straight away
        by the path unit, so the login is the only case this interval governs.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "Claude Code package the servers and the login probe run.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--no-create-session-in-dir" ];
      description = ''
        Arguments for `claude remote-control`, such as `--capacity` or
        `--permission-mode`.

        `--no-create-session-in-dir` is the default because the servers here
        are started by the machine rather than by someone about to use one.
        Without it each server pre-creates a session at startup so there is
        somewhere to type immediately, which means one idle Claude Code process
        per directory on a machine nobody may touch that day. With it the
        server waits and creates a session when someone picks the directory in
        the app, at the cost of a few seconds on first connection.

        Set to `[ ]` to get the pre-created sessions back.
      '';
      example = [
        "--permission-mode"
        "acceptEdits"
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services."claude-rc@" = {
      Unit = {
        Description = "Claude Code Remote Control in %f";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        # Leaves a broken instance in `failed` rather than restarting it
        # forever, which is what turns it into an alert instead of a restart
        # loop nobody sees. Five attempts 30s apart take two and a half
        # minutes.
        StartLimitIntervalSec = 600;
        StartLimitBurst = 5;
      };
      Service = {
        Type = "simple";
        ExecStart = "${lib.getExe runner} %f";
        # `always` rather than `on-failure` so a server that exits cleanly,
        # which happens when the last session in it ends, comes straight back
        # instead of waiting for the next scan.
        Restart = "always";
        RestartSec = 30;
      };
    };

    systemd.user.services.claude-rc-scan = {
      Unit = {
        Description = "Start and stop Claude Code Remote Control instances";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe scanner;
      };
      # Runs at login as well as on the timer, so the servers are up without
      # waiting for the first tick.
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.timers.claude-rc-scan = {
      Unit.Description = "Start and stop Claude Code Remote Control instances";
      Timer = {
        OnStartupSec = "90s";
        OnUnitActiveSec = "${toString cfg.scanIntervalSeconds}s";
      };
      Install.WantedBy = [ "timers.target" ];
    };

    # Notices a project directory being created or removed within seconds,
    # rather than at the next tick.
    #
    # Watches the roots only. Extending this to the Claude Code directory to
    # catch a login as it happens would trigger a rescan on every file the CLI
    # writes there, and a rescan runs the CLI: the timer covers that case at a
    # fixed cost instead.
    systemd.user.paths.claude-rc-scan = lib.mkIf (cfg.projectDirs != [ ]) {
      Unit.Description = "Watch project roots for new directories";
      Path.PathChanged = cfg.projectDirs;
      Install.WantedBy = [ "paths.target" ];
    };

    # Being logged out stops every server from starting and nothing else
    # reports it. Failing here puts it in the same place as any other broken
    # user unit, so one check covers both.
    systemd.user.services.claude-rc-login = {
      Unit.Description = "Report whether the Claude Code CLI is logged in";
      Service = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "claude-rc-login-check" ''
          state="$XDG_RUNTIME_DIR/claude-rc"

          # Say nothing until the scanner has finished a run, which is what
          # creates this directory and writes the marker in it. The timer can
          # otherwise fire first and report a logged-out CLI that nobody has
          # checked yet, and claude-rc-scan already reports its own failures.
          if [ ! -d "$state" ]; then
            exit 0
          fi

          if [ -e "$state/logged-in" ]; then
            exit 0
          fi

          echo "the claude CLI is not logged in; run 'claude auth login'" >&2
          exit 1
        '';
      };
    };

    systemd.user.timers.claude-rc-login = {
      Unit.Description = "Report whether the Claude Code CLI is logged in";
      # Later than the scanner's first run, which is what writes the marker.
      Timer = {
        OnStartupSec = "3min";
        OnUnitActiveSec = "${toString cfg.scanIntervalSeconds}s";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
