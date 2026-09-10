{
  description = "Alan's home-manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      # master, not a release branch: only master has the `programs.claude-code`
      # module that manages plugins, skills and marketplaces.
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Decrypts this flake's own secrets at activation, using the identity the
    # host delivers. Home-manager module, so nothing here needs the NixOS side.
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    claude-remote-control.url = "path:../../home-manager/claude-remote-control";
    # Publishes a Claude Code release within hours of it shipping. nixpkgs
    # takes days, which is long enough to matter for a CLI that changes weekly.
    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      claude-remote-control,
      agenix,
      claude-code-nix,
      ...
    }:
    {
      # Import this to activate the configuration alongside something else,
      # e.g. `home-manager.users.alan = inputs.alan.homeModules.alan;`. It
      # carries every module it depends on, so a consumer imports this alone.
      homeModules.alan =
        { pkgs, ... }:
        {
          imports = [
            claude-remote-control.homeModules.default
            agenix.homeManagerModules.default
            ./home.nix
          ];
          programs.claude-code.package = claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      # Activate this with `home-manager switch` where nothing else does it.
      # Keyed by machine because the package set is per-system; the content is
      # the same module either way.
      homeConfigurations."alan@dumbunz" = home-manager.lib.homeManagerConfiguration {
        # obsidian is unfree. A consumer of homeModules.alan has to allow it in
        # the package set it passes in.
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        modules = [
          self.homeModules.alan
          {
            home.username = "alan";
            home.homeDirectory = "/home/alan";
          }
        ];
      };
    };
}
