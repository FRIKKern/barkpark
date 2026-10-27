#!/usr/bin/env bash
# Register the Entra ID app a Barkpark organization signs in through.
# Guide: docs/setup/ENTRA.md. Needs the Azure CLI, signed in with `az login`
# as a user who may create app registrations and groups.
#
# Safe to run again. A second run finds the app by --app-id or by name, and the
# service principal and group, and sets the same settings again. It creates a
# client secret only when the app has none, or with --rotate-secret.
#
# The client secret goes only to --secret-file, written with mode 600. It is
# never printed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/entra-app-register.sh --host HOST --org SLUG [--secret-file PATH] [options]

  --host HOST            Public host name of the Barkpark instance, no scheme.
  --org SLUG             Barkpark organization slug. It is part of the redirect
                         URI, so choose it before you register the app.
  --secret-file PATH     File that receives the client secret, mode 600. Needed
                         when the app has no secret yet and with --rotate-secret.
  --app-id APPID         Use this existing app registration (its Application
                         client id) instead of finding the app by --name. Use it
                         for an app made in the portal.
  --name NAME            App display name. Default: "Barkpark <org>".
  --owners-group NAME    Security group mapped to owner. Default: "Barkpark <org> owners".
                         Give it with --app-id when the group has another name.
  --add-owner UPN        Add this user to the owners group. Repeatable.
  --group-claims MODE    application or security. Default: application when the
                         tenant has Entra ID P1, else security. See ENTRA.md.
  --secret-years N       Client secret lifetime in years, 1 or 2. Default: 1.
  --rotate-secret        Create a new client secret. Without it a rerun never
                         creates one while the app has a secret.
EOF
}

HOST="" ORG="" SECRET_FILE="" NAME="" GROUP_NAME="" GROUP_CLAIMS="" APP_ID=""
YEARS=1 ROTATE=0
OWNERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --org) ORG="${2:?}"; shift 2 ;;
    --secret-file) SECRET_FILE="${2:?}"; shift 2 ;;
    --app-id) APP_ID="${2:?}"; shift 2 ;;
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

if [ -z "$HOST" ] || [ -z "$ORG" ]; then
  usage >&2
  exit 2
fi
case "$HOST" in
  http://*|https://*|*/*) echo "--host takes a host name only, such as barkpark.example.com" >&2; exit 2 ;;
esac
case "$GROUP_CLAIMS" in
  ""|application|security) ;;
  *) echo "--group-claims must be application or security" >&2; exit 2 ;;
esac
case "$YEARS" in 1|2) ;; *) echo "--secret-years must be 1 or 2" >&2; exit 2 ;; esac
if [ "$ROTATE" = 1 ] && [ -z "$SECRET_FILE" ]; then
  echo "--rotate-secret needs --secret-file for the new secret" >&2
  exit 2
fi

GROUP_NAME="${GROUP_NAME:-Barkpark $ORG owners}"
REDIRECT="https://$HOST/v1/auth/oidc/$ORG/callback"
GRAPH="00000003-0000-0000-c000-000000000000"
# Microsoft Graph delegated scopes openid, profile and email.
SCOPES="37f7f235-527c-4136-accd-4a02d197296e=Scope 14dad69e-099b-42c9-810b-d002981feec1=Scope 64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0=Scope"
DEFAULT_ACCESS="00000000-0000-0000-0000-000000000000"

say() { printf '%s\n' "$*" >&2; }

command -v az >/dev/null || { say "the Azure CLI (az) is not installed"; exit 1; }
TENANT=$(az account show --query tenantId -o tsv) || { say "run az login first"; exit 1; }

# 0. Group claims. "application" needs Entra ID P1. A tenant has P1 when an
# enabled subscription carries an AAD_PREMIUM service plan (P2 includes it).
if [ "$GROUP_CLAIMS" != security ]; then
  P1=$(az rest --method GET --uri "https://graph.microsoft.com/v1.0/subscribedSkus" \
    --query "length(value[?capabilityStatus=='Enabled' || capabilityStatus=='Warning'].servicePlans[] | [?starts_with(servicePlanName, 'AAD_PREMIUM')])" \
    -o tsv 2>/dev/null) || P1=""
  if [ "$P1" = 0 ]; then
    if [ "$GROUP_CLAIMS" = application ]; then
      say "This tenant has no Entra ID P1, and --group-claims application needs it."
      say "Run again with --group-claims security. See docs/setup/ENTRA.md."
      exit 1
    fi
    say "Note: this tenant has no Entra ID P1, so groups come as --group-claims security."
    say "Without P1 there is no Conditional Access. See docs/setup/ENTRA.md for MFA."
    GROUP_CLAIMS=security
  elif [ -z "$P1" ] && [ -z "$GROUP_CLAIMS" ]; then
    say "Note: could not read the tenant's licenses. Using --group-claims application."
  fi
fi
case "${GROUP_CLAIMS:-application}" in
  application) CLAIMS_VALUE="ApplicationGroup" ;;
  security) CLAIMS_VALUE="SecurityGroup" ;;
esac

# 1. App registration: Web platform, single tenant, the exact redirect URI.
if [ -n "$APP_ID" ]; then
  FOUND=$(az ad app show --id "$APP_ID" --query displayName -o tsv 2>/dev/null) || FOUND=""
  if [ -z "$FOUND" ]; then
    say "No app registration with application id $APP_ID in tenant $TENANT"
    exit 1
  fi
  NAME="$FOUND"
else
  NAME="${NAME:-Barkpark $ORG}"
  APP_ID=$(az ad app list --display-name "$NAME" --query "[0].appId" -o tsv)
fi

# Decide on the client secret before changing anything. Entra never shows a
# secret again, so a rerun without the secret file must not make another one.
SECRET_COUNT=0
if [ -n "$APP_ID" ]; then
  SECRET_COUNT=$(az ad app show --id "$APP_ID" --query "length(passwordCredentials)" -o tsv)
fi
if [ "$ROTATE" = 1 ]; then
  SECRET_ACTION=create
elif [ -n "$SECRET_FILE" ] && [ -s "$SECRET_FILE" ]; then
  SECRET_ACTION=keep
elif [ "$SECRET_COUNT" != 0 ]; then
  SECRET_ACTION=existing
elif [ -n "$SECRET_FILE" ]; then
  SECRET_ACTION=create
else
  say "The app has no client secret yet. Run again with --secret-file PATH."
  exit 2
fi

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
# Admin consent right after `permission add` can miss a scope, so retry with a
# short backoff until the tenant-wide grant holds all three scopes.
GRAPH_SP=$(az ad sp show --id "$GRAPH" --query id -o tsv)
consent_granted() {
  local granted
  granted=" $(az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId%20eq%20'$SP_ID'%20and%20resourceId%20eq%20'$GRAPH_SP'%20and%20consentType%20eq%20'AllPrincipals'" \
    --query "value[].scope" -o tsv 2>/dev/null | tr '\t\n' '  ') "
  for scope in openid profile email; do
    case "$granted" in *" $scope "*) ;; *) return 1 ;; esac
  done
}
CONSENTED=0
for wait in 5 10 20 30 0; do
  az ad app permission admin-consent --id "$APP_ID" >/dev/null 2>&1 || true
  if consent_granted; then CONSENTED=1; break; fi
  if [ "$wait" != 0 ]; then
    say "Admin consent for openid, profile and email is not there yet. Trying again in ${wait}s."
    sleep "$wait"
  fi
done
if [ "$CONSENTED" != 1 ]; then
  say "ERROR: admin consent for openid, profile and email was not granted after 5 tries."
  say "No tenant-wide oauth2PermissionGrant from this app to Microsoft Graph holds all three."
  say "Sign in as a Global or Privileged Role Administrator and run this script again,"
  say "or grant it in the portal under API permissions."
  exit 1
fi
say "Admin consent for openid, profile and email is granted"

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
case "$SECRET_ACTION" in
  create)
    say "Creating client secret \"$SECRET_NAME\" for $YEARS year(s)"
    (
      umask 077
      az ad app credential reset --id "$APP_ID" --append --display-name "$SECRET_NAME" \
        --years "$YEARS" --query password -o tsv >"$SECRET_FILE.tmp"
      mv -f "$SECRET_FILE.tmp" "$SECRET_FILE"
    )
    chmod 600 "$SECRET_FILE"
    ;;
  keep)
    chmod 600 "$SECRET_FILE"
    say "Keeping the client secret in $SECRET_FILE. Use --rotate-secret for a new one."
    ;;
  existing)
    say "The app already has $SECRET_COUNT client secret(s). No new secret was created:"
    az ad app show --id "$APP_ID" \
      --query "passwordCredentials[].join(' ', ['  name:', displayName || '(none)', 'expires:', endDateTime])" \
      -o tsv >&2
    say "Entra never shows a secret again. It belongs in the Barkpark connection and in"
    say "the secret file you kept from the run that created it. Pass that file with"
    say "--secret-file. If nobody has it, run with --rotate-secret --secret-file PATH."
    ;;
esac
# A new secret is refused (AADSTS7000215) for some seconds after Entra creates
# it, and the 2026-10-27 drill saw refusals now and then for 9 minutes more.
# Wait until the token endpoint accepts it three times in a row, then tell the
# operator to wait 10 minutes before storing it in Barkpark. The secret goes to
# curl from the file, never on argv.
secret_accepted() {
  curl -fsS -o /dev/null --max-time 15 -X POST \
    "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APP_ID" --data-urlencode "client_secret@$SECRET_FILE" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
    --data-urlencode "grant_type=client_credentials" 2>/dev/null
}
if [ "$SECRET_ACTION" = create ]; then
  say "Waiting until Entra accepts the new secret"
  ok=0
  for _ in $(seq 1 60); do
    if secret_accepted; then ok=$((ok + 1)); else ok=0; fi
    [ "$ok" -ge 3 ] && break
    sleep 5
  done
  if [ "$ok" -ge 3 ]; then
    say "Entra accepts the new secret. It can still refuse it now and then for about"
    say "10 minutes. Store it in Barkpark 10 minutes after this line, and keep the old"
    say "secret until then."
  else
    say "Entra did not accept the new secret within 5 minutes. Keep the old secret"
    say "in Barkpark and run this check again before you store the new one."
  fi
fi
if [ "$SECRET_ACTION" = create ]; then
  EXPIRES=$(az ad app show --id "$APP_ID" \
    --query "sort_by(passwordCredentials[?displayName=='$SECRET_NAME'], &endDateTime)[-1].endDateTime" -o tsv)
else
  EXPIRES=$(az ad app show --id "$APP_ID" \
    --query "sort_by(passwordCredentials, &endDateTime)[-1].endDateTime" -o tsv)
fi
if [ -n "$SECRET_FILE" ] && [ "$SECRET_ACTION" != existing ]; then
  SECRET_ARG="\"\$(cat $SECRET_FILE)\""
else
  SECRET_ARG="\"<client secret>\""
fi

MAPPING="{\"$GROUP_ID\":\"owner\"}"
cat <<EOF

Tenant id:         $TENANT
Client id:         $APP_ID
Owners group id:   $GROUP_ID
Redirect URI:      $REDIRECT
Sign-in URL:       https://$HOST/v1/auth/oidc/$ORG/start
Group claims:      $CLAIMS_VALUE
Secret file:       ${SECRET_FILE:-not given}
Secret expires:    ${EXPIRES:-unknown}

Sign-ins stop when the secret expires. The commands below store the expiry
date, and Barkpark warns 30, 14 and 7 days ahead when
BARKPARK_TOKEN_EXPIRY_WARNINGS=on. Next, as a Barkpark operator. --yes answers
bp's confirmation for a write to a server that is not on this machine:

bp org create $ORG <display name> --yes
bp org attach-workspace $ORG default --yes
bp org oidc-create $ORG "https://login.microsoftonline.com/$TENANT/v2.0" "$APP_ID" $SECRET_ARG \\
  --tenant_id "$TENANT" --scopes "openid profile email" --strict_validation \\
  --client_secret_expires_at "${EXPIRES:-<expiry date>}" \\
  --set group_role_mappings:='$MAPPING' --yes

When the connection already exists, set the scopes and the mapping with:

bp org oidc-update $ORG --scopes "openid profile email" --set group_role_mappings:='$MAPPING' --yes

After a test sign-in with MFA at the sign-in URL, count Entra MFA as Barkpark MFA:

bp org oidc-update $ORG --trust_idp_mfa --yes

After a new secret, store it with:

bp org oidc-rotate-secret $ORG $SECRET_ARG --client_secret_expires_at "${EXPIRES:-<expiry date>}" --yes

Instance settings that go with this connection, described in docs/setup/ENTRA.md:
BARKPARK_OIDC_KEEP_OWNER=on BARKPARK_OIDC_EMAIL_FROM_UPN=on
EOF
