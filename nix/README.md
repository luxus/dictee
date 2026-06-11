# Nix / NixOS

dictee ships a standalone flake at the repository root (`flake.nix`) and derivations under `nix/`. Both classic Nix and flake-based workflows are supported.

> **Note:** dictee is a voice dictation stack — Rust ASR daemons, Python/Qt UI, KDE plasmoid, and push-to-talk via evdev/dotool. There is no `nix run`; install as a package and enable the Home Manager / NixOS modules.

## Build / inspect

```bash
# Build into ./result
nix build github:luxus/dictee#dictee-cuda
ls result/bin/transcribe-daemon

# Evaluate checks
nix flake check github:luxus/dictee
```

## NixOS (system-level)

The NixOS module loads `uinput`, installs dotool udev rules, and adds users to the `input` group:

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.dictee.nixosModules.default ];

  programs.dictee = {
    enable = true;
    package = inputs.dictee.packages.${pkgs.system}.dictee-cuda;
    users = [ "luxus" ];
  };
}
```

## Home Manager

Per-user services (dotoold, ASR daemon, push-to-talk). First-run hotkey/model config can be done with `dictee-setup`, or supply `~/.config/dictee.conf` declaratively:

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.dictee.homeManagerModules.default ];

  programs.dictee = {
    enable = true;
    package = inputs.dictee.packages.${pkgs.system}.dictee-cuda;
    service.enable = true;
    sessionTarget = "plasma-workspace.target"; # KDE-only scoping on multi-session hosts
  };
}
```

Parakeet TDT model files (~2.4 GB fp32) live under `~/.local/share/dictee/tdt/` and are downloaded on first use (via `dictee-setup` or a custom oneshot).

## Classic Nix (no flakes)

```bash
nix-build nix/dictee.nix
```

## Reporting issues

Nix-specific build failures: open an issue with `nix --version` and `nix flake metadata` output.