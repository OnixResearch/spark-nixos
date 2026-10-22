# Fails when spark-nixos's own pins drift from the vendored kindling-spark-os release: mentat and
# py-spy against its Dockerfile, and dispram's OGKM headers against its default stack. A cluster
# that mixes Ubuntu-image and NixOS boxes then runs one mentat release, and dispram builds against
# the headers it was validated with. The checks only compare. A bump still changes the pins by hand,
# since a source hash cannot be derived from an image digest or a commit.
{ pkgs, mentatVersion, pySpyVersion, pySpyAarch64Hash, dispramStack }:

pkgs.runCommand "kindling-pins-check" { nativeBuildInputs = [ pkgs.python3 pkgs.yq-go ]; } ''
  vendor=${../../vendor/kindling-spark-os}
  status=0
  same() {
    if [ "$2" != "$3" ]; then
      echo "$1: vendored kindling-spark-os has $2, spark-nixos pins $3" >&2
      status=1
    fi
  }
  arg() { sed -n "s/^ARG $1=//p" "$vendor/Dockerfile"; }
  hex() { python3 -c 'import base64, sys; print(base64.b64decode(sys.argv[1].split("-", 1)[1]).hex())' "$1"; }

  same mentat "$(arg MENTATD_IMAGE | sed 's/^[^:]*:\([^@]*\)@.*/\1/')" ${mentatVersion}
  same py-spy "$(arg PY_SPY_VERSION)" ${pySpyVersion}
  same "py-spy aarch64 wheel sha256" "$(arg PY_SPY_SHA256)" "$(hex ${pySpyAarch64Hash})"

  stack=$(yq '.default' "$vendor/stacks.yaml")
  same "OGKM commit of stack $stack" \
    "$(yq ".stacks.\"$stack\".ogkm_commit" "$vendor/stacks.yaml")" ${dispramStack.rev}
  same "driver release of stack $stack" \
    "$(yq ".stacks.\"$stack\".driver" "$vendor/stacks.yaml" | cut -d- -f1)" ${dispramStack.version}

  [ "$status" = 0 ]
  touch "$out"
''
