{
  description = "virtual environments";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  inputs.systems.url = "github:nix-systems/default";

  inputs.devshell.url = "github:numtide/devshell";
  inputs.devshell.inputs.nixpkgs.follows = "nixpkgs";
  inputs.devshell.inputs.systems.follows = "systems";

  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

  outputs =
    inputs@{
      flake-parts,
      devshell,
      systems,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ devshell.flakeModule ];

      systems = import systems;

      perSystem =
        { pkgs, ... }:
        {
          devshells.default = {
            devshell.packages = with pkgs; [
              typst
              typstyle
              tinymist
            ];
            env = [
              {
                name = "FONTCONFIG_FILE";
                value = pkgs.makeFontsConf {
                  fontDirectories = with pkgs; [
                    comic-relief
                    source-han-sans
                  ];
                };
              }
            ];
          };
        };
    };
}
