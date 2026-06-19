# eitype with pinned layout index — skips KDE qdbus probe (Qt 6.11 SIGSEGV on exit).
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  libxkbcommon,
  writeShellScriptBin,
}:

let
  eitype-unwrapped = rustPlatform.buildRustPackage rec {
    pname = "eitype";
    version = "0.2.2";

    src = fetchFromGitHub {
      owner = "Adam-D-Lewis";
      repo = "eitype";
      rev = version;
      hash = "sha256-s5g6METDi8/jPEwZursorYWN8X96VlyVPtd8dCCVIlw=";
    };

    cargoHash = "sha256-k0JU3Y83aPHgQpyiG6DXxBzdYSMOmH42kPCxXWtNtkQ=";

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ libxkbcommon ];

    meta = with lib; {
      description = "Type text on Wayland via the EI protocol (XDG RemoteDesktop portal)";
      homepage = "https://github.com/Adam-D-Lewis/eitype";
      license = licenses.asl20;
      mainProgram = "eitype";
    };
  };
in
writeShellScriptBin "eitype" ''
  exec ${eitype-unwrapped}/bin/eitype --layout-index 0 "$@"
''