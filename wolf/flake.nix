{
  description = "Wolf (Games on Whales) NixOS module with digest-pinned container images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    wolf-nvidia-vol = {
      url = "github:altano/flakes?dir=wolf-nvidia-vol";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      wolf-nvidia-vol,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # Digest pins, the image-ref helper, and the built-in catalog — pure
      # (no pkgs), so they're reusable from the flake's lib output.
      containers = builtins.fromJSON (builtins.readFile ./generated/containers.json);
      image =
        name: tag:
        let
          img =
            containers.${name}.${tag} or (throw "wolf: no pinned digest for ${name}:${tag} in containers.json");
        in
        "${img.image}@${img.digest}";

      # Raw catalog (images as { name; tag; }); socketPath only affects wolf-ui's
      # mount/env, irrelevant to the outputs below, so a placeholder is fine.
      rawApps = import ./apps.nix { socketPath = "/run/wolf/wolf.sock"; };
      defaultApps = builtins.mapAttrs (
        _: app:
        if app ? runner && app.runner ? imageRef then
          app
          // {
            runner = (removeAttrs app.runner [ "imageRef" ]) // {
              image = image app.runner.imageRef.name app.runner.imageRef.tag;
            };
          }
        else
          app
      ) rawApps;

      # Single source of truth for what update-containers.sh pins: every image
      # the catalog references, plus core/companion images not tied to an app.
      # Derived from the catalog so adding an app needs no second list.
      coreImages = [
        {
          name = "wolf";
          tag = "stable";
        }
        {
          name = "wolf";
          tag = "buildcache";
        }
        {
          name = "wolf";
          tag = "alpha";
        }
        {
          name = "pulseaudio";
          tag = "master";
        }
        {
          name = "wolf-den";
          tag = "stable";
        }
      ];
      appImageRefs = builtins.filter (r: r != null) (
        map (app: app.runner.imageRef or null) (builtins.attrValues rawApps)
      );
      trackedImages = {
        registry = "ghcr.io/games-on-whales";
        images = nixpkgs.lib.foldl' (
          acc: r: acc // { ${r.name} = nixpkgs.lib.unique ((acc.${r.name} or [ ]) ++ [ r.tag ]); }
        ) { } (appImageRefs ++ coreImages);
      };
    in
    {
      # The Wolf NixOS module. Consume via:
      #   imports = [ inputs.wolf.nixosModules.default ];
      #   services.wolf = { enable = true; uuid = "..."; ... };
      nixosModules.default = import ./module.nix { inherit wolf-nvidia-vol; };

      # Reusable building blocks: the parsed pins, the image-ref helper, the
      # resolved built-in catalog, and the tracked-image set the updater reads.
      lib = {
        inherit
          containers
          image
          defaultApps
          trackedImages
          ;
      };

      # The set of images/tags update-containers.sh refreshes. Exposed top-level
      # so the updater package can embed it (no second hand-maintained list).
      inherit trackedImages;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          # `nix run .#update-containers` (from the wolf/ directory) refreshes
          # containers.json against the live registry.
          update-containers = pkgs.writeShellApplication {
            name = "update-containers";
            runtimeInputs = [
              pkgs.skopeo
              pkgs.jq
            ];
            # Embed the tracked-image list (derived from the catalog) so the
            # script needs no tracked.json and no nix-eval at runtime.
            text = ''
              export WOLF_TRACKED=${nixpkgs.lib.escapeShellArg (builtins.toJSON trackedImages)}
              ${builtins.readFile ./update-containers.sh}
            '';
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          # Run the config-merge unit tests.
          merge-config =
            pkgs.runCommand "wolf-merge-config-tests"
              {
                nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.tomli-w ])) ];
              }
              ''
                cp ${./merge-config.py} merge-config.py
                cp ${./test-merge-config.py} test-merge-config.py
                python3 test-merge-config.py
                touch $out
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          # Tools for regenerating containers.json (skopeo inspect + jq), running
          # the merge tests, and formatting.
          default = pkgs.mkShell {
            packages = [
              pkgs.skopeo
              pkgs.jq
              pkgs.nixfmt
              pkgs.shellcheck
              (pkgs.python3.withPackages (ps: [ ps.tomli-w ]))
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
