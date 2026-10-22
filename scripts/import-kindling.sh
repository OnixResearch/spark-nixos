# Vendors the kindling-spark-os files spark-nixos uses, at one upstream tag or commit:
#
#   nix run .#import-kindling -- v0.9.8
#
# Copies the files listed below from github.com/kindlingai/kindling-spark-os into
# vendor/kindling-spark-os, applies patches/kindling-spark-os/*.patch in name order, and
# records the source in vendor/kindling-spark-os.json. checks.<system>.vendor rebuilds the
# tree from that record and fails when the vendored files differ from it, so change a vendored
# file with a patch, never by editing it.

owner=kindlingai
repo=kindling-spark-os
dest=vendor/kindling-spark-os
record=vendor/kindling-spark-os.json
patches=patches/kindling-spark-os
files=(
  LICENSE
  VERSION
  Dockerfile
  stacks.yaml
  agent/README.md
  agent/spark-agent.py
  agent/spark-memory.py
  dispram
  overlay/usr/local/bin/spark-console
  overlay/usr/local/bin/spark-log-snapshot.sh
  overlay/usr/local/bin/spark-logo
  overlay/usr/local/bin/spark-watchdog.py
  overlay/usr/local/sbin/sparkos-mentatd-check
  overlay/usr/local/sbin/sparkos-mtu
  overlay/usr/share/kindling
)

if [ $# -ne 1 ]; then
  echo "usage: import-kindling <tag or commit>" >&2
  exit 2
fi
if [ ! -f flake.nix ] || [ ! -d "$patches" ]; then
  echo "run this from the root of the spark-nixos checkout" >&2
  exit 2
fi
ref=$1
url=https://github.com/$owner/$repo

# A tag names the commit it points at. An annotated tag's commit is its peeled ref.
if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
  rev=$ref
else
  refs=$(git ls-remote "$url" "refs/tags/$ref" "refs/tags/$ref^{}")
  rev=$(awk '$2 ~ /\^\{\}$/ { print $1 }' <<<"$refs")
  [ -n "$rev" ] || rev=$(awk 'NR == 1 { print $1 }' <<<"$refs")
  if [ -z "$rev" ]; then
    echo "$repo has no tag $ref" >&2
    exit 1
  fi
fi

# The same tarball fetchFromGitHub unpacks, so the recorded hash is the one the check uses.
prefetch=$(nix-prefetch-url --unpack --print-path "$url/archive/$rev.tar.gz")
src=$(sed -n 2p <<<"$prefetch")
hash=$(nix hash convert --hash-algo sha256 --to sri "$(sed -n 1p <<<"$prefetch")")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/tree"
for f in "${files[@]}"; do
  if [ ! -e "$src/$f" ]; then
    echo "$repo $ref has no $f" >&2
    exit 1
  fi
done
# One entry at a time: the store's directories are read-only, and cp --parents would copy that
# onto a parent before the next entry needs to go into it.
for f in "${files[@]}"; do
  mkdir -p "$work/tree/$(dirname "$f")"
  cp -r "$src/$f" "$work/tree/$f"
  chmod -R u+w "$work/tree/$f"
done

count=0
for p in "$patches"/*.patch; do
  [ -e "$p" ] || continue
  if ! patch --quiet --batch --no-backup-if-mismatch -p1 -d "$work/tree" -i "$PWD/$p"; then
    echo "$p does not apply to $repo $ref. Update it, then import again." >&2
    exit 1
  fi
  count=$((count + 1))
done

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -r "$work/tree" "$dest"
jq -n --arg owner "$owner" --arg repo "$repo" --arg ref "$ref" --arg rev "$rev" --arg hash "$hash" \
  '{owner: $owner, repo: $repo, ref: $ref, rev: $rev, hash: $hash, files: $ARGS.positional}' \
  --args "${files[@]}" >"$record"

echo "vendored $repo $ref ($rev) with $count patches into $dest"
