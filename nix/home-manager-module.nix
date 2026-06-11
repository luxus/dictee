# Home Manager module for dictee (per-user systemd services).
#
#   imports = [ dictee.homeManagerModules.default ];
#   programs.dictee = {
#     enable = true;
#     package = dictee.packages.${system}.dictee-cuda;
#     service.enable = true;   # ASR daemon + push-to-talk daemon
#   };
#
# First-run configuration (hotkey, language, model download) is done with the
# `dictee-setup` GUI, which writes ~/.config/dictee.conf. The services read
# that file via EnvironmentFile, so run dictee-setup once before enabling them.
#
# NOTE: the user must be in the `input` group (see the NixOS module) for the
# push-to-talk daemon to read keyboards and type via /dev/uinput.
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
      description = "The dictee package to use.";
    };

    service.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the dictee systemd user services: dotoold (virtual keyboard),
        the Parakeet ASR daemon (dictee), and the push-to-talk daemon
        (dictee-ptt).
      '';
    };

    sessionTarget = lib.mkOption {
      type = lib.types.str;
      default = "graphical-session.target";
      example = "plasma-workspace.target";
      description = ''
        systemd target that scopes dictee user services to a compositor session.
        Use plasma-workspace.target on KDE so daemons do not leak into Hyprland
        or Niri on multi-session machines.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services = lib.mkIf cfg.service.enable {
      dotoold = {
        Unit = {
          Description = "dotool daemon (virtual keyboard input for dictee)";
          Documentation = "https://git.sr.ht/~geb/dotool";
          Before = [ "dictee-ptt.service" ];
        };
        Service = {
          Type = "simple";
          ExecStart = "${lib.getExe' pkgs.dotool "dotoold"}";
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ cfg.sessionTarget ];
      };

      dictee = {
        Unit = {
          Description = "dictee Parakeet ASR daemon";
          After = [ cfg.sessionTarget ];
          PartOf = [ cfg.sessionTarget ];
        };
        Service = {
          Type = "simple";
          # The wrapped binary already sets ORT_DYLIB_PATH.
          ExecStart = "${cfg.package}/bin/transcribe-daemon";
          ExecStartPost = "${pkgs.bash}/bin/bash -c 'echo idle > /dev/shm/.dictee_state'";
          Restart = "on-failure";
          RestartSec = 5;
          EnvironmentFile = "-%h/.config/dictee.conf";
        };
        Install.WantedBy = [ cfg.sessionTarget ];
      };

      dictee-ptt = {
        Unit = {
          Description = "dictee push-to-talk daemon";
          After = [
            "dotoold.service"
            "dictee.service"
            cfg.sessionTarget
          ];
          PartOf = [ cfg.sessionTarget ];
        };
        Service = {
          Type = "simple";
          # No `sg input` wrapper: on NixOS the user is in the input group
          # declaratively (programs.dictee.users in the NixOS module).
          ExecStart = "${cfg.package}/bin/dictee-ptt";
          Restart = "on-failure";
          RestartSec = 3;
          EnvironmentFile = "-%h/.config/dictee.conf";
        };
        Install.WantedBy = [ cfg.sessionTarget ];
      };
    };
  };
}
