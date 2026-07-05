#!/usr/bin/env bash
# Live IdP interop lane: boot a real Keycloak, run the opt-in `idp_interop`
# tests (Barkpark OIDC RP + SAML SP driven through full handshakes against it),
# tear it down. The self-hosted leg of SSO verification — zero external
# accounts. See api/test/barkpark_web/idp_interop/keycloak_interop_test.exs.
#
# Plain `docker run` (no compose dependency): one container, one port, one
# realm import.
set -uo pipefail
cd "$(dirname "$0")/.."

NAME="barkpark-idp-interop"
IMAGE="quay.io/keycloak/keycloak:26.0"
REALM_JSON="$(pwd)/api/test/support/idp_interop/realm.json"
KC_REALM_URL="http://localhost:8081/realms/barkpark"

echo "==> booting Keycloak (imports the barkpark realm)"
docker rm -f "$NAME" >/dev/null 2>&1
# create + docker-cp (NOT a bind mount): a -v from an unshared host path (e.g.
# /private/tmp on macOS) silently mounts an EMPTY DIRECTORY and the realm
# import no-ops. docker cp works regardless of VM file sharing.
docker create --name "$NAME" \
  -p 8081:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  "$IMAGE" start-dev --import-realm >/dev/null || exit 1
# Copy as a DIRECTORY: /opt/keycloak/data/import doesn't exist in the fresh
# container and `docker cp` of a single file won't create it — a directory
# copy to a non-existent destination does.
STAGE="$(mktemp -d)"
cp "$REALM_JSON" "$STAGE/realm.json"
# docker cp preserves modes and the container runs as uid 1000 — mktemp's 700
# root-owned dir would be unreadable ("ERROR: directory not found" at boot).
chmod 755 "$STAGE"
chmod 644 "$STAGE/realm.json"
docker cp "$STAGE" "$NAME":/opt/keycloak/data/import || exit 1
rm -rf "$STAGE"
docker start "$NAME" >/dev/null || exit 1

echo "==> waiting for the realm to come up"
ready=""
for _ in $(seq 1 60); do
  if curl -sf "$KC_REALM_URL" >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done

if [ -z "$ready" ]; then
  echo "ERROR: Keycloak did not become ready on $KC_REALM_URL" >&2
  docker logs --tail 50 "$NAME"
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 1
fi

echo "==> running the interop suite"
(cd api && MIX_ENV=test mix test --only idp_interop)
rc=$?

echo "==> tearing down"
docker rm -f "$NAME" >/dev/null 2>&1

exit $rc
