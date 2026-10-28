#!/usr/bin/env bash
# deploy_airgap.sh - verify and deploy an offline release bundle with zero internet access.
#
# Usage:   ./deploy_airgap.sh <path/to/release_vX.Y.Z.tar.gz> [install_dir]
# Layout:  <install_dir>/.env                  site secrets (created once from .env.example, never in a bundle)
#          <install_dir>/releases/release_vX   extracted, verified bundles
#          <install_dir>/current, previous     symlinks used for rollback
set -euo pipefail

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

BUNDLE_TGZ="${1:?usage: $0 <release_vX.Y.Z.tar.gz> [install_dir]}"
INSTALL_DIR="${2:-/opt/eoir-stack}"
PROJECT="eoir-stack"

for cmd in docker sha256sum tar gzip; do
  command -v "$cmd" > /dev/null 2>&1 || die "required command not found: $cmd"
done
docker compose version > /dev/null 2>&1 || die "docker compose plugin not available"
[ -f "$BUNDLE_TGZ" ] || die "bundle not found: $BUNDLE_TGZ"

NAME="$(basename "$BUNDLE_TGZ" .tar.gz)"
BUNDLE_DIR="$(cd "$(dirname "$BUNDLE_TGZ")" && pwd)"

# 1. Verify the transfer media (outer checksum), if shipped alongside
if [ -f "$BUNDLE_DIR/${NAME}.tar.gz.sha256" ]; then
  ( cd "$BUNDLE_DIR" && sha256sum --check --strict --quiet "${NAME}.tar.gz.sha256" ) \
    || die "outer checksum mismatch for ${NAME}.tar.gz - media corrupted or tampered"
  log "outer archive checksum OK"
fi

# Site secrets live outside the bundle and must exist before anything is touched
ENV_FILE="$INSTALL_DIR/.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE - create it once from the bundle's .env.example (chmod 600), then re-run"

# 2. Extract to a staging dir and verify EVERY file before anything is loaded or started
mkdir -p "$INSTALL_DIR/releases"
STAGE="$(mktemp -d "$INSTALL_DIR/releases/.incoming.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$BUNDLE_TGZ" -C "$STAGE"
SRC="$STAGE/$NAME"
[ -f "$SRC/SHA256SUMS" ] || die "SHA256SUMS missing from bundle"

( cd "$SRC" && sha256sum --check --strict --quiet SHA256SUMS ) \
  || die "SHA256SUMS verification FAILED - nothing loaded, nothing started"
# No extra, unlisted files may ride along
listed="$(sed 's/^[0-9a-f]\{64\}  //' "$SRC/SHA256SUMS" | LC_ALL=C sort)"
present="$(cd "$SRC" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort)"
[ "$listed" = "$present" ] || die "bundle contains files not covered by SHA256SUMS"
log "all files verified against SHA256SUMS"

VERSION="$(sed -n 's/^version=//p' "$SRC/RELEASE")"
BUNDLE_ARCH="$(sed -n 's/^arch=//p' "$SRC/RELEASE")"
case "$(uname -m)" in
  x86_64) HOST_ARCH=amd64 ;;
  aarch64|arm64) HOST_ARCH=arm64 ;;
  *) HOST_ARCH="$(uname -m)" ;;
esac
[ "$BUNDLE_ARCH" = "$HOST_ARCH" ] || die "bundle is for $BUNDLE_ARCH but this host is $HOST_ARCH"

# Engine must still match its manifest (independent of SHA256SUMS)
expected="$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' "$SRC/models/manifest.json")"
echo "${expected}  $SRC/models/eo_detector_fp16.engine" | sha256sum --check --strict --quiet \
  || die "engine does not match models/manifest.json"

# 3. Move verified release into place
DEST="$INSTALL_DIR/releases/$NAME"
if [ -e "$DEST" ]; then
  { [ ! -L "$INSTALL_DIR/current" ] || [ "$(readlink -f "$INSTALL_DIR/current")" != "$(readlink -f "$DEST")" ]; } \
    || die "$NAME is already the current release"
  rm -rf "$DEST"
fi
mv "$SRC" "$DEST"
find "$DEST/models" -type d -exec chmod 0755 {} +
find "$DEST/models" -type f -exec chmod 0644 {} +   # readable by the non-root container user

# 4. Load images offline
log "loading images"
for img in "$DEST"/images/*.tar.gz; do
  gunzip -c "$img" | docker load
done

# 5. The release decides the image tag, not a stale .env
export IMAGE_TAG="$VERSION"

compose() { docker compose -p "$PROJECT" --env-file "$ENV_FILE" -f "$1/docker-compose.yml" "${@:2}"; }

start_release() {  # start_release <release_dir>
  ( cd "$1" && compose "$1" up -d --no-build --pull never --wait --wait-timeout 180 )
}

smoke_test() {  # smoke_test <release_dir>  (runs inside the container: no curl needed on the host)
  compose "$1" exec -T vision_api python /app/healthcheck.py http://127.0.0.1:8000/health 200 \
    && compose "$1" exec -T vision_api python /app/healthcheck.py http://127.0.0.1:8000/api/v1/detect 200
}

PREV=""
[ -L "$INSTALL_DIR/current" ] && PREV="$(readlink -f "$INSTALL_DIR/current")"

# 6. Start, verify, and switch symlinks - or roll back automatically
log "starting $NAME (no internet, no pulls, no builds)"
if start_release "$DEST" && smoke_test "$DEST"; then
  [ -n "$PREV" ] && ln -sfn "$PREV" "$INSTALL_DIR/previous"
  ln -sfn "$DEST" "$INSTALL_DIR/current"
  log "SUCCESS: $NAME is live (health 200, detect 200)"
else
  log "FAILED: $NAME did not become healthy"
  compose "$DEST" ps || true
  compose "$DEST" logs --tail 50 inference_worker vision_api || true
  if [ -n "$PREV" ] && [ -d "$PREV" ]; then
    log "rolling back to $(basename "$PREV")"
    export IMAGE_TAG="$(sed -n 's/^version=//p' "$PREV/RELEASE")"
    start_release "$PREV" && smoke_test "$PREV" && log "rollback OK" || die "rollback FAILED - escalate"
  fi
  exit 1
fi
