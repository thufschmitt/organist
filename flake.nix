{
  description = "Nickel shim for Nix";
  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nickel.url = "github:tweag/nickel/master";
  inputs.topiary.follows = "nickel/topiary";

  nixConfig = {
    extra-substituters = [
      "https://tweag-nickel.cachix.org"
      "https://tweag-topiary.cachix.org"
    ];
    extra-trusted-public-keys = [
      "tweag-nickel.cachix.org-1:GIthuiK4LRgnW64ALYEoioVUQBWs0jexyoYVeLDBwRA="
      "tweag-topiary.cachix.org-1:8TKqya43LAfj4qNHnljLpuBnxAY/YwEBfzo3kzXxNY0="
    ];
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    nickel,
    topiary,
  } @ inputs:
    {
      templates =
        (
          let
            inherit (nixpkgs) lib;
            brokenShells = ["javascript" "php" "python310"];
            filteredShells = (
              lib.filterAttrs
              (name: value: !(builtins.elem name brokenShells))
              (builtins.readDir ./templates/devshells)
            );
          in
            lib.mapAttrs'
            (
              name: value:
                lib.nameValuePair
                (name + "-devshell")
                {
                  path = ./templates/devshells/${name};
                  description = "A ${name} devshell using nickel.";
                  welcomeText = ''
                    You have created a ${name} devshell that is built using nickel!

                    First run `nix run .#regenerate-lockfile` to fill `nickel.lock.ncl` with proper references.

                    Then run `nix develop --impure` to enter the dev shell.
                  '';
                }
            )
            filteredShells
        )
        // {};
    }
    // flake-utils.lib.eachDefaultSystem (
      system: let
        lib = import ./lib.nix;
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        lib.importNcl = pkgs.callPackage lib.importNcl {
          inherit system;
          nickel = inputs.nickel.packages."${system}".nickel;
        };

        lib.nakedStdenv = nixpkgs: self.lib.${system}.importNcl ./. "naked-stdenv.ncl" {inherit nixpkgs;};

        # Helper function that generates ugly contents for "nickel.lock.ncl", see buildLockFile.
        lib.buildLockFileContents = contents: let
          lib = pkgs.lib;
          getLinesOne = name: thing:
            if lib.isAttrs thing
            then
              [
                ((lib.optionalString (name != null) "${name} = ") + "{")
              ]
              ++ lib.mapAttrsToList getLinesOne thing
              ++ [
                ("}" + (lib.optionalString (name != null) ","))
              ]
            else [''${name} = import "${builtins.toString thing}",''];
        in
          lib.concatLines (lib.flatten (getLinesOne null contents));

        # A script that generates contents of "nickel.lock.ncl" file from a recursive attribute set of strings.
        # File contents is piped through topiary to make them pretty and check for correctnes
        # Example inputs:
        #   {
        #     nickel-nix = {
        #       builders = "/nix/store/...-source/builders.ncl";
        #       contracts = "/nix/store/...-source/contracts.ncl";
        #       naked-stdenv = "/nix/store/...-source/naked-stdenv.ncl";
        #       nix = "/nix/store/...-source/nix.ncl";
        #     };
        #   }
        # Result:
        #   {
        #     nickel-nix = {
        #       builders = import "/nix/store/...-source/builders.ncl",
        #       contracts = import "/nix/store/...-source/contracts.ncl",
        #       naked-stdenv = import "/nix/store/...-source/naked-stdenv.ncl",
        #       nix = import "/nix/store/...-source/nix.ncl",
        #     },
        #   }
        lib.buildLockFile = contents:
          pkgs.writeShellApplication {
            name = "regenerate-lockfile";
            text = ''
              ${pkgs.lib.getExe topiary.packages.${system}.default} -l nickel > nickel.lock.ncl <<EOF
              ${self.lib.${system}.buildLockFileContents contents}
              EOF
            '';
          };

        # Flake app to generate nickel.lock.ncl file. Example usage:
        #   apps = {
        #     regenerate-lockfile = nickel-nix.lib.${system}.regenerateLockFileApp {
        #       nickel-nix = nickel-nix.lib.${system}.lockFileContents;
        #     };
        #   };
        lib.regenerateLockFileApp = contents: {
          type = "app";
          program = pkgs.lib.getExe (self.lib.${system}.buildLockFile contents);
        };

        # Provide an attribute set of all .ncl libraries in the root directory of this flake
        lib.lockFileContents = pkgs.lib.pipe ./. [
          # Collect all items in the directory like {"examples": "directory", "nix.ncl": regular, ...}
          builtins.readDir
          # List only regular files with .ncl suffix
          (files:
            pkgs.lib.concatMap (
              name:
                pkgs.lib.optional
                (files.${name} == "regular" && (pkgs.lib.hasSuffix ".ncl" name))
                name
            ) (pkgs.lib.attrNames files))
          # Generate attrs with file name without .ncl as a key: {nix = "/nix/store/...-source/nix.ncl";}
          (map (f: pkgs.lib.nameValuePair (pkgs.lib.removeSuffix ".ncl" f) "${./.}/${f}"))
          pkgs.lib.listToAttrs
        ];

        devShells.default = pkgs.mkShell {
          packages = [
            inputs.nickel.packages."${system}".nickel
          ];
        };
      }
    );
}
