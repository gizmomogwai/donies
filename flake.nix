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
          # requests is a git dependency; dub would call git in the sandbox, so use a path dependency instead
          dubLock = let
            lock = pkgs.lib.importJSON ./dub-lock.json;
          in
            lock // {dependencies = builtins.removeAttrs lock.dependencies ["requests"];};
          requests = pkgs.fetchFromGitHub {
            owner = "gizmomogwai";
            repo = "dlang-requests";
            rev = "750643e5651956b1bdcfbe5ff287c7f3964f1f59";
            hash = "sha256-R+OEhXeUF6inxkfBAxvDzNDKfqocCu85frLfz1yF5Z4=";
          };
          postPatch = ''
            cp -r --no-preserve=mode $requests ../requests
            sed -i 's|^dependency "requests" .*|dependency "requests" path="../requests"|' dub.sdl
            sed -i 's|"requests": {.*}|"requests": {"path": "../requests"}|' dub.selections.json
          '';
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
