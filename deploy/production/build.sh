#!/bin/sh
set -eu
SHA=${CI_COMMIT_SHA:?CI_COMMIT_SHA required}
case "$SHA" in *[!0-9a-f]*|'') exit 1;; esac
[ "${#SHA}" -eq 40 ]
[ "$(git rev-parse HEAD)" = "$SHA" ]
BUILDER=vm2api-production
VERSION=$(tr -d '\r\n' < VERSION)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Preserve the upstream Dockerfile and add only bounded build parallelism.
awk '
  { print }
  / AS web$/ { print "ENV NODE_OPTIONS=--max-old-space-size=2048"; web++ }
  / AS helpers$/ { print "ENV GOMAXPROCS=2 GOFLAGS=-p=2"; helpers++ }
  END { if(web != 1 || helpers != 1) exit 1 }
' Dockerfile > "$TMP/Dockerfile"
docker buildx inspect --bootstrap "$BUILDER" >/dev/null
docker buildx build --builder "$BUILDER" --platform linux/amd64 \
  -f "$TMP/Dockerfile" --provenance=false --load \
  --label "org.opencontainers.image.revision=$SHA" \
  --label "org.opencontainers.image.version=$VERSION" \
  --label 'org.opencontainers.image.source=https://github.com/zengwenliang416/vm2api' \
  -t "local/vm2api:$SHA" .
[ "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "local/vm2api:$SHA")" = "$SHA" ]
printf 'Built vm2api %s at %s\n' "$VERSION" "$SHA"
