{
  description = "rdr: a minimal terminal PDF viewer for the kitty graphics protocol";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # rdr waits on kqueue and is only tested on macOS.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "rdr";
          version = "0.1.0";

          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./build.zig
              ./src
            ];
          };

          nativeBuildInputs = [ pkgs.zig_0_17.hook ];
          buildInputs = [ pkgs.mupdf ];

          # The Zig hook adds -Dcpu=baseline and --release=safe.
          zigBuildFlags = [ "-Dhomebrew=false" ];
          zigCheckFlags = [ "-Dhomebrew=false" ];
          doCheck = true;

          meta = {
            description = "Minimal terminal PDF viewer for the kitty graphics protocol";
            homepage = "https://github.com/dzania/rdr";
            mainProgram = "rdr";
            platforms = pkgs.lib.platforms.darwin;
          };
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
