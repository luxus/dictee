# parakeet-rs — the Rust ASR core of dictee.
#
# Builds the `transcribe*` / `diarize-only` binaries from the in-tree
# parakeet-rs crate. We use ONNX Runtime in `load-dynamic` mode: the binaries
# dlopen libonnxruntime.so at runtime (via ORT_DYLIB_PATH set by the wrapper),
# so the build never downloads a prebuilt ORT (forbidden in the Nix sandbox).
#
# `cudaSupport` switches the ONNX Runtime to a CUDA-enabled build and compiles
# the ort CUDA execution-provider bindings. The actual CUDA EP is provided by
# the dynamic libonnxruntime.so at runtime.
{
  lib,
  rustPlatform,
  cmake,
  clang,
  llvmPackages,
  pkg-config,
  onnxruntime,
  cudaSupport ? false,
  cudaPackages ? { },
}:

let
  cargoToml = builtins.fromTOML (builtins.readFile ../Cargo.toml);
in
rustPlatform.buildRustPackage {
  pname = "parakeet-rs";
  version = cargoToml.package.version;

  src = lib.cleanSource ../.;
  cargoLock.lockFile = ../Cargo.lock;

  # Drop the default ["cpu" "ort-defaults"] features: `ort-defaults` pulls
  # ort/download-binaries which fetches a prebuilt ONNX Runtime over the
  # network. We provide ORT ourselves via load-dynamic instead.
  buildNoDefaultFeatures = true;
  buildFeatures = [
    "load-dynamic"
    "sortformer"
  ]
  ++ lib.optionals cudaSupport [ "cuda" ];

  nativeBuildInputs = [
    cmake
    clang
    pkg-config
  ]
  ++ lib.optionals cudaSupport [ cudaPackages.cuda_nvcc ];

  buildInputs = [
    onnxruntime
  ]
  ++ lib.optionals cudaSupport [
    cudaPackages.cudatoolkit
    cudaPackages.cudnn
  ];

  env = {
    # bindgen (onig-sys via tokenizers) needs libclang.
    LIBCLANG_PATH = "${lib.getLib llvmPackages.libclang}/lib";

    # Build oniguruma (tokenizers `onig` feature) statically and vendored,
    # mirroring upstream PKGBUILD. Avoids a system-lib dependency.
    RUSTONIG_STATIC_LIBONIG = "1";

    # Where ort-sys looks for ONNX Runtime. Harmless under load-dynamic but
    # keeps ort from attempting any download fallback during the build.
    ORT_LIB_LOCATION = "${lib.getLib onnxruntime}/lib";
  };

  # The crate's lib tests load ONNX model files that are fetched at runtime by
  # dictee-setup and are not present in the source tree, so the unit tests
  # cannot run hermetically in the sandbox.
  doCheck = false;

  meta = {
    description = "Rust ASR core (NVIDIA Parakeet via ONNX Runtime) used by dictee";
    homepage = "https://github.com/rcspam/dictee";
    license = lib.licenses.gpl3Plus;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
