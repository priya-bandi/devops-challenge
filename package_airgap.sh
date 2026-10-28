#!/usr/bin/env bash
# package_airgap.sh - build a versioned, checksummed offline release bundle.
#
# Usage:   ./package_airgap.sh [version]          (default: version from models/manifest.json)
# Output:  dist/release_v<version>.tar.gz  +  dist/release_v<version>.tar.gz.sha256
# Bundle:  images/*.tar.gz, docker-compose.yml, .env.example, models/, deploy_airgap.sh,
#          RUNBOOK.md, IMAGES, RELEASE, SHA256SUMS (covers every other file in the bundle)
set -euo pipefail

cd "$(dirname "$0")"

log() { printf '[package] %s\n' "$*"; }
die() { printf '[package] ERROR: %s\n' "$*" >&2; exit 1; }

for cmd in docker sha256sum tar gzip sed find sort xargs; do
  command -v "$cmd" > /dev/null 2>&1 || die "required command not found: $cmd"
done

json_field() {  # json_field <key> <file>  (flat string fields only, no python needed)
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2" | head -n 1
}

MANIFEST=models/manifest.json
ENGINE=models/eo_detector_fp16.engine
VERSION="${1:-$(json_field version "$MANIFEST")}"
[ -n "$VERSION" ] || die "cannot determine version"
IMAGE_REPO="${IMAGE_REPO:-eoir-stack}"
APP_IMAGE="${IMAGE_REPO}:${VERSION}"
PG_IMAGE="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(postgres:[^[:space:]]*\).*/\1/p' docker-compose.yml | head -n 1)"
BUNDLE="release_v${VERSION}"
OUT_DIR="${OUT_DIR:-dist}"

# 1. Release gate: the engine must match its manifest, and the manifest must match the release version
expected="$(json_field sha256 "$MANIFEST")"
[ -n "$expected" ] || die "no sha256 in $MANIFEST"
echo "${expected}  ${ENGINE}" | sha256sum --check --strict --quiet \
  || die "$ENGINE does not match the sha256 in $MANIFEST - refusing to package"
[ "$(json_field version "$MANIFEST")" = "$VERSION" ] \
  || die "manifest version does not match release version $VERSION"
log "model artifact verified (sha256 ${expected:0:12}...)"

# 2. Images: build the app image with an immutable version tag; make sure the postgres image is local
log "building $APP_IMAGE"
docker build -t "$APP_IMAGE" .
[ -n "$PG_IMAGE" ] || die "postgres image not found in docker-compose.yml"
docker image inspect "$PG_IMAGE" > /dev/null 2>&1 || docker pull "$PG_IMAGE"
ARCH="$(docker image inspect -f '{{.Architecture}}' "$APP_IMAGE")"

# 3. Stage the bundle
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/$BUNDLE"
mkdir -p "$ROOT/images"

log "exporting images"
docker save "$APP_IMAGE" | gzip -c > "$ROOT/images/${IMAGE_REPO}_${VERSION}.tar.gz"
docker save "$PG_IMAGE"  | gzip -c > "$ROOT/images/$(printf '%s' "$PG_IMAGE" | tr ':/' '__').tar.gz"

cp docker-compose.yml .env.example deploy_airgap.sh RUNBOOK.md "$ROOT/"
cp -R models "$ROOT/models"
rm -rf "$ROOT/models/.trt_cache"
chmod 0755 "$ROOT/deploy_airgap.sh"
find "$ROOT/models" -type f -exec chmod 0644 {} +

printf '%s\n' "$APP_IMAGE" "$PG_IMAGE" > "$ROOT/IMAGES"
cat > "$ROOT/RELEASE" <<EOF
version=${VERSION}
arch=${ARCH}
app_image=${APP_IMAGE}
postgres_image=${PG_IMAGE}
engine_sha256=${expected}
git_commit=$(git rev-parse --short HEAD 2> /dev/null || echo unknown)
built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# 4. SHA256SUMS over every file in the bundle (relative paths, stable order)
( cd "$ROOT" \
  && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS )

# 5. Single versioned archive + outer checksum for the transfer media
mkdir -p "$OUT_DIR"
tar -C "$STAGE" -czf "$OUT_DIR/${BUNDLE}.tar.gz" "$BUNDLE"
( cd "$OUT_DIR" && sha256sum "${BUNDLE}.tar.gz" > "${BUNDLE}.tar.gz.sha256" )

log "bundle:   $OUT_DIR/${BUNDLE}.tar.gz ($ARCH, $(wc -l < "$ROOT/SHA256SUMS") files checksummed)"
log "checksum: $OUT_DIR/${BUNDLE}.tar.gz.sha256"
