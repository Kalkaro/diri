#!/usr/bin/env bash
# Regenerates nix/cargo-git-hashes.json: the hash of each Git source in
# diri/Cargo.lock. With a source's hash the flake fetches only the pinned
# commit; without one it clones the whole repository with every branch, tag
# and pull request, over a gigabyte for Zed. The Nix hashes workflow runs this
# whenever Cargo.lock or the flake changes on main.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hashes_file="${root}/nix/cargo-git-hashes.json"

case "${1:-}" in
    "") ;;
    -h|--help)
        echo "usage: ./scripts/update-nix-hashes.sh"
        exit 0
        ;;
    *)
        echo "error: unknown option: $1" >&2
        echo "usage: ./scripts/update-nix-hashes.sh" >&2
        exit 2
        ;;
esac

if ! command -v nix >/dev/null 2>&1; then
    echo "error: nix is required" >&2
    exit 1
fi

# The fetchgit call importCargoLock makes for a hashed Git source, from the
# flake's locked nixpkgs so the hash matches what the flake will check.
# Building it with a placeholder hash fails and reports the real one.
fetch_expr='
{ root, url, rev }:
let
  lock = builtins.fromJSON (builtins.readFile (root + "/flake.lock"));
  pkgs = import (builtins.fetchTree lock.nodes.nixpkgs.locked) {
    config = { };
    overlays = [ ];
  };
in
pkgs.fetchgit {
  inherit url rev;
  hash = pkgs.lib.fakeHash;
}'

entries=""
while IFS= read -r source; do
    # Parsed like importCargoLock does: git+URL[?rev=...|tag=...|branch=...]#COMMIT
    url="${source#git+}"
    url="${url%%#*}"
    url="${url%%\?*}"
    rev="${source##*#}"
    echo "==> ${url} ${rev}" >&2
    log="$(nix --extra-experimental-features "nix-command flakes" build --no-link --impure \
        --expr "${fetch_expr}" --argstr root "${root}" --argstr url "${url}" --argstr rev "${rev}" \
        </dev/null 2>&1)" || true
    hash="$(sed -n 's/^ *got: *\(sha256-[^ ]*\).*/\1/p' <<<"${log}")"
    if [[ -z "${hash}" ]]; then
        printf '%s\n' "${log}" >&2
        echo "error: could not determine the hash of ${url} at ${rev}" >&2
        exit 1
    fi
    entries+="${entries:+,
}  \"${source}\": \"${hash}\""
done < <(sed -n 's/^source = "\(git+.*\)"$/\1/p' "${root}/diri/Cargo.lock" | sort -u)

mkdir -p "$(dirname "${hashes_file}")"
printf '{\n%s\n}\n' "${entries}" >"${hashes_file}"
echo "wrote ${hashes_file#"${root}/"}" >&2
