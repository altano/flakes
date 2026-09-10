# Alan's home configuration, shared by every machine he uses.
#
# Reads nothing outside home-manager's own option space, so the same module
# works wherever it is activated.
#
# This repository is public. No cleartext keys, tokens or passwords.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  home.stateVersion = "25.11";

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Alan Norbauer";
        email = "alan@norbauer.com";
      };
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      merge.conflictStyle = "diff3";
      diff.colorMoved = "default";
      core.pager = "delta";
      delta.navigate = true;
      interactive.diffFilter = "delta --color-only";
    };
  };

  # Loads a directory's .envrc on cd. nix-direnv caches the devShell so
  # re-entering a directory does not re-evaluate its flake.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  home.file.".config/htop/htoprc".source = ./dotfiles/htoprc;

  # Keeps the key with the rest of the configuration. A machine that has never
  # activated this config has to provide its own way in.
  home.file.".ssh/authorized_keys".text = ''
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHzWY7ZSnlszb0sO42PREJeZGUlZdZlyXQG/JiJKGu9Y
  '';

  # Owns Claude Code's user configuration. `settings.json` becomes a read-only
  # symlink into the store, so `/config` cannot write to it and every setting
  # has to be declared here.
  #
  # Needs home-manager master: the release branches ship an older module
  # without plugins, skills or marketplaces.
  programs.claude-code = {
    enable = true;
    settings = {
      # Starts the Remote Control bridge with every session, so a session here
      # can be picked up from the Claude mobile or web app without running
      # /remote-control first. Only the user and policy tiers can switch this
      # on: a repository's own settings can set it to false to opt out, but
      # setting it true there is ignored.
      remoteControlAtStartup = true;
    };
  };

  # A server per project directory, kept up whether or not anyone is logged
  # in. Directories are ranked by mtime, so the ones touched most recently are
  # the ones reachable from the phone.
  services.claude-remote-control = {
    enable = true;
    acceptWorkspaceTrust = true;
    # Runs the same CLI the module above installs, so overriding one package
    # cannot leave the servers on a different version.
    package = config.programs.claude-code.package;
    projectDirs = [
      "${config.home.homeDirectory}/src"
      "${config.home.homeDirectory}/code"
      "${config.home.homeDirectory}/Projects"
    ];
  };

  # Devices and folders are declared, not paired in the GUI: home-manager
  # rewrites both on every activation, so anything added through the web UI is
  # discarded. The host opens the sync ports and orders this after the home
  # mount; see configuration/services/user-vm in the infrastructure repo.
  # Secrets this flake decrypts itself. The identity is delivered by whatever
  # host the config is activated on: on a user VM, papa writes it there from
  # its own agenix store. Files here are encrypted to that identity's public
  # half plus the people listed in secrets/secrets.nix.
  age.identityPaths = [ "/run/agenix/owner-age-identity" ];
  age.secrets."syncthing-key".file = ./secrets/syncthing-key.age;

  services.syncthing = {
    enable = true;
    # A stable device ID. Without these syncthing mints a new identity
    # whenever its config directory is recreated, and every peer has to
    # re-accept this machine. The cert is the public half, so it is checked
    # in; the key is decrypted by the identity papa delivers.
    cert = builtins.toString ./secrets/syncthing-cert.pem;
    key = config.age.secrets."syncthing-key".path;
  };

  home.sessionVariables = {
    EDITOR = "nano";
    VISUAL = "nano";
  };

  home.packages = [
    pkgs.git
    pkgs.nano
    pkgs.htop
    pkgs.ripgrep
    pkgs.fd
    pkgs.obsidian
    # Backs the git pager settings above.
    pkgs.delta
    # Ghostty sends TERM=xterm-ghostty, which the machine being logged into has
    # to know or less, htop and vim fail with an unknown terminal.
    pkgs.ghostty.terminfo
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    # trash-put, which the safe-delete skill calls on Linux. Not on macOS,
    # which has its own /usr/bin/trash: trash-cli also installs a `trash`
    # alias, and that one rejects the -s flag the skill relies on to make a
    # failed move exit non-zero.
    pkgs.trash-cli
  ];
}
