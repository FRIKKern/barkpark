#!/usr/bin/env bash
# Register the Entra ID app a Barkpark organization signs in through.
# Guide: docs/setup/ENTRA.md. Needs the Azure CLI, signed in with `az login`
# as a user who may create app registrations and groups.
#
# Safe to run again. A second run finds the app, service principal and group by
# name, sets the same settings again and keeps the existing client secret while
# the secret file holds one. --rotate-secret creates a new secret.
#
# The client secret goes only to --secret-file, written with mode 600. It is
# never printed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/entra-app-register.sh --host HOST --org SLUG --secret-file PATH [options]

  --host HOST            Public host name of the Barkpark instance, no scheme.
  --org SLUG             Barkpark organization slug. It is part of the redirect
                         URI, so choose it before you register the app.
  --secret-file PATH     File that receives the client secret, mode 600.
  --name NAME            App display name. Default: "Barkpark <org>".
  --owners-group NAME    Security group mapped to owner. Default: "Barkpark <org> owners".
  --add-owner UPN        Add this user to the owners group. Repeatable.
  --group-claims MODE    application (default) or security. See ENTRA.md.
  --secret-years N       Client secret lifetime in years, 1 or 2. Default: 1.
  --rotate-secret        Create a new client secret even when the file holds one.
EOF
}

HOST="" ORG="" SECRET_FILE="" NAME="" GROUP_NAME="" GROUP_CLAIMS="application"
YEARS=1 ROTATE=0
OWNERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --org) ORG="${2:?}"; shift 2 ;;
    --secret-file) SECRET_FILE="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --owners-group) GROUP_NAME="${2:?}"; shift 2 ;;
    --add-owner) OWNERS+=("${2:?}"); shift 2 ;;
    --group-claims) GROUP_CLAIMS="${2:?}"; shift 2 ;;
    --secret-years) YEARS="${2:?}"; shift 2 ;;
    --rotate-secret) ROTATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$HOST" ] || [ -z "$ORG" ] || [ -z "$SECRET_FILE" ]; then
  usage >&2
  exit 2
fi
case "$HOST" in
  http://*|https://*|*/*) echo "--host takes a host name only, such as barkpark.example.com" >&2; exit 2 ;;
esac
case "$GROUP_CLAIMS" in
  application) CLAIMS_VALUE="ApplicationGroup" ;;
  security) CLAIMS_VALUE="SecurityGroup" ;;
  *) echo "--group-claims must be application or security" >&2; exit 2 ;;
esac
case "$YEARS" in 1|2) ;; *) echo "--secret-years must be 1 or 2" >&2; exit 2 ;; esac

NAME="${NAME:-Barkpark $ORG}"
GROUP_NAME="${GROUP_NAME:-Barkpark $ORG owners}"
REDIRECT="https://$HOST/v1/auth/oidc/$ORG/callback"
GRAPH="00000003-0000-0000-c000-000000000000"
# Microsoft Graph delegated scopes openid, profile and email.
SCOPES="37f7f235-527c-4136-accd-4a02d197296e=Scope 14dad69e-099b-42c9-810b-d002981feec1=Scope 64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0=Scope"
DEFAULT_ACCESS="00000000-0000-0000-0000-000000000000"

say() { printf '%s\n' "$*" >&2; }

command -v az >/dev/null || { say "the Azure CLI (az) is not installed"; exit 1; }
TENANT=$(az account show --query tenantId -o tsv) || { say "run az login first"; exit 1; }

# 1. App registration: Web platform, single tenant, the exact redirect URI.
APP_ID=$(az ad app list --display-name "$NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  say "Creating app registration \"$NAME\""
  APP_ID=$(az ad app create --display-name "$NAME" --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "$REDIRECT" --query appId -o tsv)
else
  say "Found app registration \"$NAME\" ($APP_ID)"
  az ad app update --id "$APP_ID" --sign-in-audience AzureADMyOrg
  # Keep other redirect URIs on the app and add this one when it is missing.
  URIS=()
  while IFS= read -r uri; do
    [ -n "$uri" ] && URIS+=("$uri")
  done <<<"$(az ad app show --id "$APP_ID" --query "web.redirectUris[]" -o tsv)"
  if ! printf '%s\n' "${URIS[@]+"${URIS[@]}"}" | grep -qxF "$REDIRECT"; then
    az ad app update --id "$APP_ID" --web-redirect-uris "${URIS[@]+"${URIS[@]}"}" "$REDIRECT"
  fi
fi

# 2. ID token claims: groups as object ids, email, amr for MFA, and the scopes.
az ad app update --id "$APP_ID" --set "groupMembershipClaims=$CLAIMS_VALUE" \
  --optional-claims '{"idToken":[{"name":"email","essential":false},{"name":"amr","essential":false}],"accessToken":[],"saml2Token":[]}'
# shellcheck disable=SC2086
az ad app permission add --id "$APP_ID" --api "$GRAPH" --api-permissions $SCOPES >/dev/null

# 3. Service principal, the enterprise app that users sign in to.
SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)
if [ -z "$SP_ID" ]; then
  say "Creating service principal"
  SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
fi
az ad app permission admin-consent --id "$APP_ID" >/dev/null 2>&1 ||
  say "Admin consent for openid, profile and email was not granted. Grant it in the portal under API permissions."

# 4. Owners security group, assigned to the app when groups come from assignments.
GROUP_ID=$(az ad group list --display-name "$GROUP_NAME" --query "[0].id" -o tsv)
if [ -z "$GROUP_ID" ]; then
  say "Creating security group \"$GROUP_NAME\""
  NICK=$(printf '%s' "$GROUP_NAME" | tr -cd 'A-Za-z0-9-')
  GROUP_ID=$(az ad group create --display-name "$GROUP_NAME" --mail-nickname "$NICK" \
    --query id -o tsv)
fi
for upn in "${OWNERS[@]+"${OWNERS[@]}"}"; do
  OID=$(az ad user show --id "$upn" --query id -o tsv)
  if [ "$(az ad group member check --group "$GROUP_ID" --member-id "$OID" --query value -o tsv)" != "true" ]; then
    say "Adding $upn to \"$GROUP_NAME\""
    az ad group member add --group "$GROUP_ID" --member-id "$OID"
  fi
done
if [ "$CLAIMS_VALUE" = "ApplicationGroup" ]; then
  ASSIGNED=$(az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignedTo" \
    --query "value[?principalId=='$GROUP_ID'] | length(@)" -o tsv)
  if [ "$ASSIGNED" = "0" ]; then
    say "Assigning \"$GROUP_NAME\" to the app"
    az rest --method POST \
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignedTo" \
      --headers "Content-Type=application/json" \
      --body "{\"principalId\":\"$GROUP_ID\",\"resourceId\":\"$SP_ID\",\"appRoleId\":\"$DEFAULT_ACCESS\"}" \
      >/dev/null || {
        say "The group could not be assigned to the app. Assigning groups needs Entra ID P1."
        say "Run again with --group-claims security, or assign the group in the portal."
        exit 1
      }
  fi
fi

# 5. Client secret, written only to the secret file.
SECRET_NAME="barkpark-$ORG"
if [ "$ROTATE" = 1 ] || [ ! -s "$SECRET_FILE" ]; then
  say "Creating client secret \"$SECRET_NAME\" for $YEARS year(s)"
  (
    umask 077
    az ad app credential reset --id "$APP_ID" --append --display-name "$SECRET_NAME" \
      --years "$YEARS" --query password -o tsv >"$SECRET_FILE.tmp"
    mv -f "$SECRET_FILE.tmp" "$SECRET_FILE"
  )
else
  say "Keeping the client secret in $SECRET_FILE. Use --rotate-secret for a new one."
fi
chmod 600 "$SECRET_FILE"
EXPIRES=$(az ad app credential list --id "$APP_ID" \
  --query "sort_by([?displayName=='$SECRET_NAME'], &endDateTime)[-1].endDateTime" -o tsv)

MAPPING="{\"$GROUP_ID\":\"owner\"}"
cat <<EOF

Tenant id:         $TENANT
Client id:         $APP_ID
Owners group id:   $GROUP_ID
Redirect URI:      $REDIRECT
Sign-in URL:       https://$HOST/v1/auth/oidc/$ORG/start
Group claims:      $CLAIMS_VALUE
Secret file:       $SECRET_FILE
Secret expires:    ${EXPIRES:-unknown}

Record the secret expiry date and rotate the secret before it. Next, as a
Barkpark operator:

bp org create $ORG <display name>
bp org attach-workspace $ORG default
bp org oidc-create $ORG "https://login.microsoftonline.com/$TENANT/v2.0" "$APP_ID" "\$(cat $SECRET_FILE)" \\
  --tenant_id "$TENANT" --scopes "openid profile email" --strict_validation \\
  --set group_role_mappings:='$MAPPING'

When the connection already exists, set the mapping with:

bp org oidc-update $ORG --set group_role_mappings:='$MAPPING'

After a new secret, store it with:

bp org oidc-rotate-secret $ORG "\$(cat $SECRET_FILE)"

Instance settings that go with this connection, described in docs/setup/ENTRA.md:
BARKPARK_OIDC_KEEP_OWNER=on BARKPARK_OIDC_EMAIL_FROM_UPN=on
EOF
