# dictee — full assembly: Rust ASR core (parakeet-rs) + Python/Qt UI + shell
# scripts + data, wired for NixOS.
#
# The Rust binaries come from ./parakeet-rs.nix. Everything else (the
# dictee-* Python and shell scripts, configs, locales, icons, systemd user
# units, KDE plasmoid) is installed here following the upstream PKGBUILD's
# package() layout, with the FHS /usr paths rewritten to $out and the scripts
# wrapped with their Python and CLI runtime dependencies.
{
  lib,
  stdenv,
  parakeet-rs,
  onnxruntime,
  makeWrapper,
  gettext,
  zip,
  python3,

  # runtime CLI tools the scripts shell out to
  eitype,
  sox,
  ffmpeg,
  libnotify,
  wl-clipboard,
  xclip,
  pulseaudio,
  wireplumber,
  translate-shell,
  curl,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  procps,

  cudaSupport ? false,
}:

let
  cargoToml = builtins.fromTOML (builtins.readFile ../Cargo.toml);

  pythonEnv = python3.withPackages (ps: [
    ps.pyqt6
    ps.evdev
    ps.numpy
  ]);

  # Tools placed on every script's PATH.
  runtimeDeps = [
    eitype
    sox
    ffmpeg
    libnotify
    wl-clipboard
    xclip
    pulseaudio
    wireplumber
    translate-shell
    curl
    coreutils
    gnugrep
    gnused
    gawk
    procps
  ];

  # Python scripts (need the pyqt6/evdev/numpy interpreter).
  # The first six are installed from <name>.py; the last two ship without a
  # suffix already but are also Python.
  pythonScripts = [
    "dictee-setup"
    "dictee-tray"
    "dictee-ptt"
    "dictee-postprocess"
    "dictee-diarize-llm"
    "dictee-transcribe"
    "dictee-cheatsheet"
    "dictee-meeting-live"
  ];

  # Shell scripts (plain bash).
  shellScripts = [
    "dictee"
    "dictee-switch-backend"
    "dictee-test-rules"
    "dictee-reset"
    "dictee-translate-langs"
  ];

  # Extra helper scripts that live under pkg/dictee/usr/bin/.
  pkgBinScripts = [
    "dictee-audio-sources"
    "dictee-plasmoid-level"
    "dictee-plasmoid-level-daemon"
    "dictee-plasmoid-level-fft"
    "transcribe-daemon-vosk"
    "transcribe-daemon-whisper"
  ];

  # The Rust ASR binaries (from parakeet-rs) — wrapped with ORT_DYLIB_PATH.
  transcribeBins = [
    "transcribe"
    "transcribe-daemon"
    "transcribe-client"
    "transcribe-diarize"
    "transcribe-stream-diarize"
    "transcribe-diarize-batch"
    "diarize-only"
  ];
in
stdenv.mkDerivation {
  pname = "dictee" + lib.optionalString cudaSupport "-cuda";
  version = cargoToml.package.version;

  src = lib.cleanSource ../.;

  nativeBuildInputs = [
    makeWrapper
    gettext
    zip
    python3
  ];

  dontBuild = true;

  # The Rust bins are already stripped by buildRustPackage; the Python scripts
  # embed binary data (base64 assets) that trips the strip hook's text reader.
  dontStrip = true;

  # Some Python scripts embed binary data (null bytes), which makes the global
  # patchShebangs scan abort. We patch the shell scripts explicitly in
  # installPhase and the Python shebangs are already rewritten to the store.
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall

    install -d $out/bin $out/lib/dictee $out/share/dictee

    # --- Rust ASR binaries (from parakeet-rs) ---
    for b in ${lib.concatStringsSep " " transcribeBins}; do
      install -Dm755 ${parakeet-rs}/bin/$b $out/bin/$b
    done

    # --- Python scripts (strip .py) ---
    install -Dm755 dictee-setup.py        $out/bin/dictee-setup
    install -Dm755 dictee-tray.py         $out/bin/dictee-tray
    install -Dm755 dictee-ptt.py          $out/bin/dictee-ptt
    install -Dm755 dictee-postprocess.py  $out/bin/dictee-postprocess
    install -Dm755 dictee-diarize-llm.py  $out/bin/dictee-diarize-llm
    install -Dm755 dictee-transcribe.py   $out/bin/dictee-transcribe

    # --- Shell scripts ---
    install -Dm755 dictee                  $out/bin/dictee
    install -Dm755 dictee-switch-backend   $out/bin/dictee-switch-backend
    install -Dm755 dictee-test-rules       $out/bin/dictee-test-rules
    install -Dm755 dictee-reset            $out/bin/dictee-reset
    install -Dm755 dictee-translate-langs  $out/bin/dictee-translate-langs
    install -Dm755 dictee-cheatsheet       $out/bin/dictee-cheatsheet
    install -Dm755 dictee-meeting-live     $out/bin/dictee-meeting-live

    # --- Extra helper scripts from pkg/dictee/usr/bin ---
    for s in ${lib.concatStringsSep " " pkgBinScripts}; do
      install -Dm755 pkg/dictee/usr/bin/$s $out/bin/$s
    done

    # Point every Python script at the withPackages interpreter directly. This
    # both fixes the `env -S python3 -u` shebang (which patchShebangs mangles)
    # and puts pyqt6/evdev/numpy on sys.path without a PYTHONPATH wrapper.
    # sed (unlike substituteInPlace) tolerates the embedded null bytes some of
    # these scripts contain (base64 asset blobs).
    for s in ${lib.concatStringsSep " " pythonScripts} \
             dictee-plasmoid-level-fft transcribe-daemon-vosk transcribe-daemon-whisper; do
      [ -f "$out/bin/$s" ] && sed -i \
        -e '1s|^#!/usr/bin/env -S python3 -u|#!${pythonEnv}/bin/python3 -u|' \
        -e '1s|^#!/usr/bin/env python3|#!${pythonEnv}/bin/python3|' \
        $out/bin/$s
    done

    # --- Shared libs / common code ---
    install -Dm644 dictee-common.sh  $out/lib/dictee/dictee-common.sh
    install -Dm644 dictee_models.py  $out/lib/dictee/dictee_models.py

    # --- Default configs ---
    for c in dictee.conf.example rules.conf.default dictionary.conf.default \
             continuation.conf.default short_text_keepcaps.conf.default; do
      install -Dm644 $c $out/share/dictee/$c
    done
    echo "${cargoToml.package.version} (nix)" > $out/share/dictee/VERSION

    # --- Locales (compile .po -> .mo) ---
    for lang in fr de es it pt uk; do
      if [ -f "po/$lang.po" ]; then
        install -d $out/share/locale/$lang/LC_MESSAGES
        msgfmt -o $out/share/locale/$lang/LC_MESSAGES/dictee.mo po/$lang.po
      fi
    done

    # --- Assets ---
    install -d $out/share/dictee/assets
    cp -r assets/*.svg $out/share/dictee/assets/ 2>/dev/null || true
    [ -d assets/logos ] && cp -r assets/logos $out/share/dictee/assets/
    [ -d assets/icons ] && cp -r assets/icons  $out/share/dictee/assets/

    # --- Icons ---
    for f in pkg/dictee/usr/share/icons/hicolor/scalable/apps/*.svg; do
      [ -f "$f" ] && install -Dm644 "$f" \
        $out/share/icons/hicolor/scalable/apps/$(basename "$f")
    done

    # --- Desktop entries ---
    for d in dictee-setup dictee-tray dictee-transcribe; do
      f=pkg/dictee/usr/share/applications/$d.desktop
      [ -f "$f" ] && install -Dm644 "$f" $out/share/applications/$d.desktop
    done

    # --- Man pages ---
    for f in pkg/dictee/usr/share/man/man1/*.1; do
      [ -f "$f" ] && install -Dm644 "$f" $out/share/man/man1/$(basename "$f")
    done
    for f in pkg/dictee/usr/share/man/fr/man1/*.1; do
      [ -f "$f" ] && install -Dm644 "$f" $out/share/man/fr/man1/$(basename "$f")
    done

    # --- systemd user units + preset (paths rewritten below) ---
    for f in pkg/dictee/usr/lib/systemd/user/*.service; do
      [ -f "$f" ] && install -Dm644 "$f" \
        $out/lib/systemd/user/$(basename "$f")
    done
    install -Dm644 pkg/dictee/usr/lib/systemd/user-preset/90-dictee.preset \
      $out/lib/systemd/user-preset/90-dictee.preset

    # --- udev / modules-load drop-ins (for the NixOS module to reference) ---
    install -Dm644 pkg/dictee/etc/udev/rules.d/80-dotool.rules \
      $out/lib/udev/rules.d/80-dotool.rules
    install -Dm644 pkg/dictee/etc/modules-load.d/dictee-uinput.conf \
      $out/lib/modules-load.d/dictee-uinput.conf

    # --- KDE plasmoid ---
    if [ -d plasmoid/package ]; then
      ( cd plasmoid/package && zip -qr "$TMPDIR/dictee.plasmoid" metadata.json contents/ )
      install -Dm644 "$TMPDIR/dictee.plasmoid" $out/share/dictee/dictee.plasmoid
    fi

    # Patch shebangs only on the (null-byte-free) shell scripts.
    patchShebangs \
      ${lib.concatMapStringsSep " " (s: "$out/bin/" + s) (shellScripts ++ [
        "dictee-audio-sources"
        "dictee-plasmoid-level"
        "dictee-plasmoid-level-daemon"
      ])}

    runHook postInstall
  '';

  # Rewrite FHS paths to the Nix store, then wrap scripts with their deps.
  postFixup = ''
    # Rewrite hardcoded /usr/{lib,share,bin}/dictee paths to point at $out, for
    # the scripts + lib files + systemd units only. We deliberately skip the
    # Rust ASR binaries: they embed "/usr/share/dictee/tdt" as a default model
    # dir, and sed-editing an ELF would change string lengths and corrupt it
    # (that default is harmless — model dirs are passed explicitly at runtime).
    # sed (not substituteInPlace) tolerates the null bytes some scripts embed.
    for f in ${lib.concatMapStringsSep " " (s: "$out/bin/" + s) (
      pythonScripts ++ shellScripts ++ pkgBinScripts
    )} $out/lib/dictee/dictee_models.py $out/lib/dictee/dictee-common.sh \
       $out/share/systemd/user/*.service; do
      [ -f "$f" ] || continue
      sed -i \
        -e "s|/usr/lib/dictee|$out/lib/dictee|g" \
        -e "s|/usr/share/dictee|$out/share/dictee|g" \
        -e "s|/usr/bin/dictee|$out/bin/dictee|g" \
        "$f"
    done

    binPath="${lib.makeBinPath runtimeDeps}:$out/bin"

    # Wrap Python scripts: CLI PATH + Qt platform plugins (the interpreter
    # already carries pyqt6/evdev/numpy via the withPackages shebang).
    for s in ${lib.concatStringsSep " " pythonScripts} dictee-plasmoid-level-fft \
             transcribe-daemon-vosk transcribe-daemon-whisper; do
      [ -f "$out/bin/$s" ] || continue
      wrapProgram "$out/bin/$s" \
        --prefix PATH : "$binPath" \
        --set-default QT_QPA_PLATFORM_PLUGIN_PATH \
          "${pythonEnv}/${python3.sitePackages}/PyQt6/Qt6/plugins/platforms"
    done

    # Wrap shell scripts: just the CLI PATH.
    for s in ${lib.concatStringsSep " " shellScripts} dictee-audio-sources \
             dictee-plasmoid-level dictee-plasmoid-level-daemon; do
      [ -f "$out/bin/$s" ] || continue
      wrapProgram "$out/bin/$s" --prefix PATH : "$binPath"
    done

    # Wrap the Rust ASR binaries: point ORT at the dynamic ONNX Runtime.
    for b in ${lib.concatStringsSep " " transcribeBins}; do
      [ -f "$out/bin/$b" ] || continue
      wrapProgram "$out/bin/$b" \
        --set-default ORT_DYLIB_PATH "${lib.getLib onnxruntime}/lib/libonnxruntime.so" \
        --prefix LD_LIBRARY_PATH : "${lib.getLib onnxruntime}/lib"
    done
  '';

  meta = {
    description = "Fast push-to-talk voice dictation for Linux (NVIDIA Parakeet ASR)";
    homepage = "https://github.com/rcspam/dictee";
    license = lib.licenses.gpl3Plus;
    mainProgram = "dictee";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
