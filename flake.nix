{
  description = "QuickNotes - reproducible build (Lab 11)";

  inputs = {
    # Pinned channel; flake.lock pins the exact revision.
    # nixos-25.11 ships Go >= 1.24, which app/go.mod requires.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          quicknotes = pkgs.buildGoModule {
            pname = "quicknotes";
            version = "0.1.0";
            src = ./app;

            # QuickNotes has zero third-party dependencies (no go.sum), so there
            # is nothing to vendor: null tells buildGoModule to skip the vendor
            # derivation. With a dependency added, Nix fails with the real hash
            # ("got: sha256-...") to paste here.
            vendorHash = null;

            env.CGO_ENABLED = 0;                 # static binary
            ldflags = [ "-s" "-w" ];             # strip symbols / DWARF
            subPackages = [ "." "healthcheck" ]; # quicknotes + healthcheck
          };

          docker = pkgs.dockerTools.buildImage {
            name = "quicknotes";
            tag = "nix";
            # No `created` override: it defaults to 1970-01-01, which keeps the
            # image digest independent of when it was built.
            extraCommands = ''
              mkdir -p app data
              cp ${./app/seed.json} app/seed.json
              chmod 0777 data   # writable by the nonroot user without chown
            '';
            config = {
              Entrypoint = [ "${quicknotes}/bin/quicknotes" ];
              ExposedPorts = { "8080/tcp" = { }; };
              User = "65532:65532";   # distroless "nonroot", as in Lab 6
              WorkingDir = "/app";
              Env = [
                "ADDR=:8080"
                "DATA_PATH=/data/notes.json"
                "SEED_PATH=/app/seed.json"
              ];
            };
          };
        in
        {
          inherit quicknotes docker;
          default = quicknotes;
        });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.go pkgs.gopls pkgs.golangci-lint ];
        };
      });
    };
}
