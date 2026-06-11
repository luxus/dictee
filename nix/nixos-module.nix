# NixOS module for dictee (system-level bits).
#
# dictee types via `dotool`, which writes to /dev/uinput, and listens to
# physical keyboards via evdev for its push-to-talk hotkey. Both need the
# `uinput` kernel module loaded and the user in the `input` group.
#
#   imports = [ dictee.nixosModules.default ];
#   programs.dictee = {
#     enable = true;
#     package = dictee.packages.${system}.dictee-cuda;
#     users = [ "luxus" ];   # added to the `input` group
#   };
#
# For the push-to-talk daemon + ASR service, also import the Home Manager
# module (per-user systemd services).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.dictee;
in
{
  options.programs.dictee = {
    enable = lib.mkEnableOption "dictee voice dictation";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dictee or null;
      defaultText = lib.literalExpression "dictee.packages.\${system}.dictee-cuda";
      description = "The dictee package to install system-wide.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "luxus" ];
      description = ''
        Users to add to the `input` group so dictee can read keyboards
        (evdev hotkey) and type via /dev/uinput (dotool).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # dotool / dictee-ptt need /dev/uinput.
    boot.kernelModules = [ "uinput" ];
    services.udev.packages = [ cfg.package ]; # ships 80-dotool.rules

    users.groups.input = { };
    users.users = lib.genAttrs cfg.users (_: {
      extraGroups = [ "input" ];
    });
  };
}
