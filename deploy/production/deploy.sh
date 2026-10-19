#!/bin/sh
set -eu
ROOT=/opt/vm2api
SHA=${CI_COMMIT_SHA:?CI_COMMIT_SHA required}
case "$SHA" in *[!0-9a-f]*|'') exit 1;; esac
[ "${#SHA}" -eq 40 ]
IMAGE="local/vm2api:$SHA"
[ "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE")" = "$SHA" ]
[ -s "$ROOT/.env" ]
mkdir "$ROOT/deployment.lock" || { echo 'Another deployment or recovery is active'; exit 1; }
trap 'rmdir "$ROOT/deployment.lock"' EXIT
[ ! -e "$ROOT/maintenance.flag" ] || { echo 'Existing maintenance requires operator inspection'; exit 1; }
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$ROOT/backups/$STAMP-$SHA"
mkdir -p "$BACKUP" "$ROOT/releases/$SHA"
chmod 700 "$BACKUP"
OLD_IMAGE=$(docker inspect -f '{{.Config.Image}}' vm2api 2>/dev/null || true)
printf '%s\n' "$OLD_IMAGE" > "$BACKUP/previous-image.txt"
cp deploy/production/compose.yaml "$ROOT/releases/$SHA/compose.yaml"
cp deploy/production/smoke.mjs "$ROOT/releases/$SHA/smoke.mjs"
printf 'VM2API_IMAGE=%s\n' "$IMAGE" > "$ROOT/releases/$SHA/image.env"
docker compose --env-file "$ROOT/releases/$SHA/image.env" -f "$ROOT/releases/$SHA/compose.yaml" config --quiet
touch "$ROOT/maintenance.flag"
# A fail-closed gate is required before stopping the writable SQLite service.
GATE=$(docker run --rm --network host curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Host: vm2api.motion-cover.com' http://127.0.0.1/healthz)
[ "$GATE" = 503 ] || { echo 'Maintenance gate not verified; leaving maintenance enabled'; exit 1; }
if [ -n "$OLD_IMAGE" ]; then docker stop -t 45 vm2api >/dev/null; fi
# These paths include DB encryption material. Backups never leave the server.
tar -czf "$BACKUP/state.tar.gz" -C "$ROOT" .env data vms bin share config
for f in compose.yaml image.env current-release.json; do
  if [ -f "$ROOT/$f" ]; then cp "$ROOT/$f" "$BACKUP/$f"; fi
done
cp "$ROOT/releases/$SHA/compose.yaml" "$ROOT/compose.yaml"
cp "$ROOT/releases/$SHA/image.env" "$ROOT/image.env"
compose() { docker compose --env-file "$ROOT/image.env" -f "$ROOT/compose.yaml" "$@"; }
validate() {
  compose up -d --wait --wait-timeout 300 || return 1
  docker exec -i vm2api node --input-type=module < "$ROOT/releases/$SHA/smoke.mjs" || return 1
  [ "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' vm2api)" = "$SHA" ]
}
if ! validate; then
  echo 'Candidate validation failed; maintenance remains enabled during recovery'
  docker stop -t 30 vm2api >/dev/null 2>&1 || true
  docker logs --tail 200 vm2api > "$BACKUP/candidate.log" 2>&1 || true
  if [ -n "$OLD_IMAGE" ] && [ -s "$BACKUP/image.env" ]; then
    # Preserve the failed candidate data and restore only while ingress is closed.
    mkdir "$BACKUP/failed-state"
    for d in data vms bin share config; do mv "$ROOT/$d" "$BACKUP/failed-state/$d"; done
    tar -xzf "$BACKUP/state.tar.gz" -C "$ROOT"
    cp "$BACKUP/compose.yaml" "$ROOT/compose.yaml"
    cp "$BACKUP/image.env" "$ROOT/image.env"
    if compose up -d --wait --wait-timeout 300; then
      rm "$ROOT/maintenance.flag"
      echo 'Previous image and pre-deployment state restored'
    fi
  fi
  exit 1
fi
VERSION=$(docker exec vm2api cat /opt/vm2api/VERSION | tr -d '\r\n')
printf '{"commit":"%s","image":"%s","version":"%s","deployed_at":"%s","backup":"%s"}\n' "$SHA" "$IMAGE" "$VERSION" "$STAMP" "$BACKUP" > "$ROOT/current-release.json.tmp"
mv "$ROOT/current-release.json.tmp" "$ROOT/current-release.json"
rm "$ROOT/maintenance.flag"
printf 'Deployed %s (%s)\n' "$IMAGE" "$VERSION"
