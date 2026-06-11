{
  description = "dictee — fast push-to-talk voice dictation for Linux (CUDA-first Nix flake)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Separate instance with allowUnfree for the CUDA stack (CUDA EULA).
        pkgsUnfree = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          config.cudaSupport = true;
        };

        onnxruntimeCuda = pkgsUnfree.onnxruntime.override { cudaSupport = true; };

        parakeet-rs = pkgs.callPackage ./nix/parakeet-rs.nix { };

        parakeet-rs-cuda = pkgsUnfree.callPackage ./nix/parakeet-rs.nix {
          cudaSupport = true;
          onnxruntime = onnxruntimeCuda;
          inherit (pkgsUnfree) cudaPackages;
        };

        dictee = pkgs.callPackage ./nix/dictee.nix {
          inherit parakeet-rs;
        };

        dictee-cuda = pkgsUnfree.callPackage ./nix/dictee.nix {
          cudaSupport = true;
          parakeet-rs = parakeet-rs-cuda;
          onnxruntime = onnxruntimeCuda;
        };
      in
      {
        packages = {
          inherit
            parakeet-rs
            parakeet-rs-cuda
            dictee
            dictee-cuda
            ;
          default = dictee;
        };

        checks = {
          inherit dictee parakeet-rs;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ parakeet-rs ];
          packages = with pkgs; [
            rust-analyzer
            rustfmt
            clippy
          ];
        };
      }
    )
    // {
      homeManagerModules.default = ./nix/home-manager-module.nix;
      nixosModules.default = ./nix/nixos-module.nix;
    };
}
