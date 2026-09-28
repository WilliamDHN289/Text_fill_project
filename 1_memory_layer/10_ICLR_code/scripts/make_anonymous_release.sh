#!/bin/sh
# Build the anonymous supplementary archive: tracked source files only, no git
# history, no results, no machine paths. Usage: sh scripts/make_anonymous_release.sh
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$root/pfm-anonymous.zip"}
tmp=$(mktemp -d)/pfm
mkdir -p "$tmp"
cd "$root"
git ls-files -z | grep -zv '^results/' | xargs -0 -I{} sh -c 'mkdir -p "$1/$(dirname {})"; cp {} "$1/{}"' _ "$tmp"
grep -rIl "$HOME" "$tmp" || true          # must print nothing
rm -f "$out"
(cd "$(dirname "$tmp")" && zip -qr "$out" pfm)
echo "wrote $out"
