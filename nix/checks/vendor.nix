# Rebuilds vendor/kindling-spark-os from the source it records and fails when the vendored files
# differ: an edit made there instead of in patches/kindling-spark-os, or a record that no longer
# matches the files.
{ pkgs }:

let
  inherit (pkgs) lib;
  record = lib.importJSON ../../vendor/kindling-spark-os.json;
  upstream = pkgs.fetchFromGitHub { inherit (record) owner repo rev hash; };
  patchDir = ../../patches/kindling-spark-os;
  patches = map (name: patchDir + "/${name}") (lib.sort lib.lessThan (lib.attrNames
    (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".patch" name)
      (builtins.readDir patchDir))));
in
pkgs.runCommand "kindling-spark-os-vendor-check" { nativeBuildInputs = [ pkgs.gnupatch ]; } ''
  mkdir expected
  for f in ${lib.escapeShellArgs record.files}; do
    mkdir -p "expected/$(dirname "$f")"
    cp -r "${upstream}/$f" "expected/$f"
    chmod -R u+w "expected/$f"
  done
  for p in ${lib.escapeShellArgs patches}; do
    patch --quiet --batch --no-backup-if-mismatch -p1 -d expected -i "$p"
  done
  if ! diff -r expected ${../../vendor/kindling-spark-os}; then
    echo "vendor/kindling-spark-os is not ${record.repo} ${record.ref} with patches/kindling-spark-os." >&2
    echo "Change vendored files through a patch, then run: nix run .#import-kindling -- ${record.ref}" >&2
    exit 1
  fi
  touch "$out"
''
