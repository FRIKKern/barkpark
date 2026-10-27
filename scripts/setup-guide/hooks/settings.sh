#!/usr/bin/env bash
# shellcheck disable=SC2154 # host, RG and the like come from the vars file.
# The guide says to replace every <...> value in barkpark.env and add the
# Pensum settings bp instance init leaves out. It gives no command.
f=barkpark.env
[ -f "$f" ] || { echo "settings: no $f in $PWD" >&2; exit 1; }
set_key() {
  if grep -q "^$1=" "$f"; then
    awk -v k="$1" -v v="$2" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' "$f" > "$f.tmp"
  else
    { cat "$f"; printf '%s=%s\n' "$1" "$2"; } > "$f.tmp"
  fi
  cat "$f.tmp" > "$f"; rm -f "$f.tmp"
}
set_key PHX_HOST "$host"
set_key BARKPARK_ALWAYS_ALLOWED_ORIGINS "https://$host,$studio_origin"
set_key BARKPARK_BOOTSTRAP_OWNER_EMAIL "$owner_email"
set_key BARKPARK_OPERATOR_EMAILS "$operator_emails"
set_key BARKPARK_BREAKGLASS_EMAILS "$breakglass_email"
set_key BARKPARK_OIDC_KEEP_OWNER on
set_key BARKPARK_OIDC_EMAIL_FROM_UPN on
if grep -n '<[^>]*>' "$f" | grep -v '^[0-9]*:#'; then
  echo "settings: placeholders left in $f" >&2; exit 1
fi
echo "settings: $f filled"
