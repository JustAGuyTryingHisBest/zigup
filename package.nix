{
  lib,
  stdenv,
  zig_0_17,
  # Embedded via -Dgit-revision; the sandbox has no .git for `git describe`.
  gitRevision ? "unknown",
}:
let
  zig = zig_0_17;
  fs = lib.fileset;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zigup";
  version = "0.1.0"; # keep in sync with build.zig.zon's .version

  src = fs.toSource {
    root = ./.;
    fileset = fs.unions [
      ./src
      ./build.zig
      ./build.zig.zon
    ];
  };

  # Fixed-output derivation: runs `zig build --fetch` against build.zig.zon.
  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) src pname version;
    hash = "sha256-iuNo/MN+4edAXqV5py+jhjH5uNYTwfqQBNZoyqhZhBk=";
  };

  # zig's setup hook creates a fresh ZIG_GLOBAL_CACHE_DIR in configurePhase;
  # seed it with the prefetched packages.
  postConfigure = ''
    cp -rLT ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
    chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  zigBuildFlags = [ "-Dgit-revision=${gitRevision}" ];

  nativeBuildInputs = [ zig ];

  meta.mainProgram = "zigup";
})
