{
  description = "donie - manage Creative Tonies via the Tonie Cloud API";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in {
      packages = forAll (pkgs: {
        default = pkgs.buildDubPackage {
          pname = "donie";
          version = self.shortRev or "dirty";
          src = ./.;
          dubLock = ./dub-lock.json;
          installPhase = ''
           runHook preInstall
                                     install -Dm755 out/main/donie -t $out/bin
                        runHook postInstall
                        '';
          };
        }
      );
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          # ldc/dub from the same nixpkgs as openssl, so the glibc versions match
          packages = [
            pkgs.ldc
            pkgs.dub
            pkgs.openssl
            # workaround: nix ssh for git; system /usr/bin/ssh breaks on LD_LIBRARY_PATH's nix libcrypto (glibc mismatch)
            pkgs.openssh
          ];
          # requests dlopens libssl.so.3 at runtime, nix ld.so does not search system lib dirs
          LD_LIBRARY_PATH = "${pkgs.openssl.out}/lib";
        };
      }
    );
    };
}
