{
  description = "zigup - a zig installer and version manager";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
    };
  };
  outputs =
    { self, ... }@inputs:
    let
      inherit (inputs.nixpkgs) lib;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forEachSupportedSystem =
        f:
        lib.genAttrs supportedSystems (
          system:
          f {
            inherit system;
            pkgs = import inputs.nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          }
        );
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs, system }:
        {
          default = pkgs.mkShellNoCC {
            inputsFrom = [ self.packages.${system}.default ];
            packages = [
              self.formatter.${system}
            ];
          };
        }
      );

      formatter = forEachSupportedSystem ({ pkgs, ... }: pkgs.nixfmt-tree);

      packages = forEachSupportedSystem (
        { pkgs, ... }:
        {
          default = pkgs.callPackage ./package.nix {
            # Match build.zig's `git describe --always --dirty --abbrev=12`.
            gitRevision =
              if self ? rev then
                lib.substring 0 12 self.rev
              else if self ? dirtyRev then
                lib.substring 0 12 self.dirtyRev + "-dirty"
              else
                "unknown";
          };
        }
      );
    };
}
