#!/usr/bin/env bash
# Build and publish a mujina-ui release.
#
#   scripts/release.sh vX.Y.Z [NOTES_FILE]
#
# Releases come only from a clean `main` that equals origin/main (static
# assets are embedded from assets/). The script tags HEAD, runs the tests,
# builds mujina-ui for the Amlogic control boards (aarch64 musl), checks the
# binary carries the tag, and publishes it with SHA256SUMS as a GitHub
# release on RY3T/mujina-ui.
set -euo pipefail
die() { echo "!! $*" >&2; exit 1; }

TAG=${1:?usage: scripts/release.sh vX.Y.Z [NOTES_FILE]}
NOTES=${2:-}
[[ $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must look like v1.2.3"
cd "$(git rev-parse --show-toplevel)"
TARGET=aarch64-unknown-linux-musl
BIN=target/$TARGET/release/mujina-ui

[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "check out main first"
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not origin/main: push or pull first"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "$TAG already exists"
[ -z "$NOTES" ] || [ -f "$NOTES" ] || die "$NOTES does not exist"

git tag -a "$TAG" -m "$TAG"
trap 'git tag -d "$TAG" >/dev/null 2>&1 || true' ERR
unset MUJINA_UI_VERSION
cargo test --quiet
cargo build --release --target "$TARGET"
grep -qa "$TAG" "$BIN" || die "the binary does not carry $TAG"
grep -qa "$TAG-dirty" "$BIN" && die "the binary was built dirty"

OUT=dist/$TAG; rm -rf "$OUT"; mkdir -p "$OUT"
cp "$BIN" "$OUT/mujina-ui-aarch64"
(cd "$OUT" && shasum -a 256 mujina-ui-aarch64 > SHA256SUMS && cat SHA256SUMS)

if [ -z "$NOTES" ]; then
  PREV=$(git describe --tags --abbrev=0 --match 'v*' "$TAG^" 2>/dev/null || true)
  NOTES=$OUT/NOTES.md
  { echo "mujina-ui (local web UI for mujina-minerd) for the Amlogic control board, aarch64."
    echo; echo "Changes${PREV:+ since $PREV}:"; echo
    git log --format='- %s (%h)' ${PREV:+$PREV..}"$TAG"; } > "$NOTES"
fi
trap - ERR
git push -q origin "$TAG"
gh release create "$TAG" -R RY3T/mujina-ui --verify-tag --title "$TAG" --notes-file "$NOTES" \
  "$OUT/mujina-ui-aarch64" "$OUT/SHA256SUMS"
echo ">> released $TAG: https://github.com/RY3T/mujina-ui/releases/tag/$TAG"
