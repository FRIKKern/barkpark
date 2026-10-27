#!/usr/bin/env bash
# Rehearses "Moving an instance" in docs/setup/SELF-HOST-OPERATIONS.md on one machine.
# A source database gets the real schema, a document with an encrypted field
# and a TOTP user. `bp instance backup` dumps it, `bp instance restore` loads
# it into a fresh Postgres cluster that only accepts TLS with a self-signed CA,
# and the prod build boots against that cluster with DATABASE_SSL=verify-full
# and the same keys. It passes when /readyz answers 200 and both values read
# back. It creates and drops its own databases and cluster.
#
#   SRC_ADMIN_URL=postgresql://localhost/postgres PG_BIN=/opt/homebrew/opt/postgresql@16/bin \
#     scripts/instance-move-rehearsal.sh
#
# PG_BIN must hold initdb, pg_ctl, pg_dump and pg_restore of the source
# server's major version. TARGET_PG_BIN, PG_BIN by default, makes the target
# cluster and runs the restore. Point it at a newer major to rehearse a VM's
# PostgreSQL 14 or 16 moving onto Flexible Server 17. The api/ prod build must
# compile (MIX_ENV=prod).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
src_admin=${SRC_ADMIN_URL:-postgresql://localhost/postgres}
pg_bin=${PG_BIN:-$(dirname "$(command -v pg_dump)")}
target_pg_bin=${TARGET_PG_BIN:-$pg_bin}
port=${MOVE_PG_PORT:-55432}
http_port=${MOVE_HTTP_PORT:-4799}
tmp=$(mktemp -d)
src_db=bp_move_src_$$
export PATH="$pg_bin:$PATH"

server_pid=
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  "$target_pg_bin/pg_ctl" -D "$tmp/pg" -m immediate stop >/dev/null 2>&1 || true
  psql "$src_admin" -qc "DROP DATABASE IF EXISTS $src_db WITH (FORCE)" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# Keys the target would load from Key Vault. They never enter the backup.
BARKPARK_CLOAK_KEY=$(openssl rand -base64 32)
BARKPARK_KEK=$(openssl rand -base64 32)
SECRET_KEY_BASE=$(openssl rand -base64 48)
PREVIEW_JWT_SECRET=$(openssl rand -base64 32)
BARKPARK_RELEASE_CAPTURE_HMAC_SECRET=$(openssl rand -hex 32)
MOVE_TOTP_SECRET=$(openssl rand -hex 20)
export BARKPARK_CLOAK_KEY BARKPARK_KEK SECRET_KEY_BASE PREVIEW_JWT_SECRET
export BARKPARK_RELEASE_CAPTURE_HMAC_SECRET MOVE_TOTP_SECRET PHX_HOST=localhost
export MIX_ENV=prod BARKPARK_SELF_UPDATE_CHECK=off

echo "== target cluster: TLS only, self-signed CA, $("$target_pg_bin/postgres" --version)"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=move-ca \
  -keyout "$tmp/ca.key" -out "$tmp/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=localhost -keyout "$tmp/server.key" -out "$tmp/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:localhost\n' >"$tmp/san.ext"
openssl x509 -req -in "$tmp/server.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -CAcreateserial \
  -days 1 -extfile "$tmp/san.ext" -out "$tmp/server.crt" 2>/dev/null
chmod 600 "$tmp/server.key"
"$target_pg_bin/initdb" -D "$tmp/pg" -U postgres --auth=trust >/dev/null
cat >>"$tmp/pg/postgresql.conf" <<EOF
port = $port
listen_addresses = 'localhost'
unix_socket_directories = '$tmp'
ssl = on
ssl_cert_file = '$tmp/server.crt'
ssl_key_file = '$tmp/server.key'
EOF
printf 'local all all trust\nhostssl all all localhost trust\nhostnossl all all all reject\n' >"$tmp/pg/pg_hba.conf"
"$target_pg_bin/pg_ctl" -D "$tmp/pg" -l "$tmp/pg.log" -w start >/dev/null
target="postgresql://postgres@localhost:$port/barkpark?sslmode=verify-full&sslrootcert=$tmp/ca.crt"
psql "postgresql://postgres@localhost:$port/postgres?sslmode=verify-full&sslrootcert=$tmp/ca.crt" -qc "CREATE DATABASE barkpark"
if psql "postgresql://postgres@localhost:$port/barkpark?sslmode=disable" -qc 'SELECT 1' >/dev/null 2>&1; then
  echo "FAIL: the target accepted a connection without TLS" >&2
  exit 1
fi

echo "== source: migrate, seed, encrypted field, TOTP user"
psql "$src_admin" -qc "CREATE DATABASE $src_db"
src_url=$(python3 -c 'import sys,urllib.parse as u; p=u.urlparse(sys.argv[1]); print(p._replace(path="/"+sys.argv[2]).geturl())' "$src_admin" "$src_db")
mix_step() { # Runs the .exs step quietly and prints its own result lines.
  (cd "$root/api" && mix run --no-start ../scripts/instance-move-rehearsal.exs "$1") >"$tmp/$1.log" 2>&1 ||
    { tail -40 "$tmp/$1.log" >&2; echo "FAIL: $1" >&2; exit 1; }
  grep -E '^(seeded|check):' "$tmp/$1.log"
}
DATABASE_URL=$src_url mix_step seed

echo "== backup and restore"
(cd "$root" && go build -o "$tmp/bp" ./cmd/barkpark)
mkdir -p "$tmp/media-src/covers" "$tmp/media-dst"
echo cover >"$tmp/media-src/covers/one.jpg"
"$tmp/bp" instance backup --database-url "$src_url" --media-dir "$tmp/media-src" --out "$tmp/backup"
# db.dump is compressed, so search its restored SQL and the unpacked media.
pg_restore -f "$tmp/dump.sql" "$tmp/backup/db.dump"
tar -xzOf "$tmp/backup/media.tar.gz" >"$tmp/media.bin"
for key in BARKPARK_CLOAK_KEY BARKPARK_KEK SECRET_KEY_BASE PREVIEW_JWT_SECRET; do
  if grep -qF "${!key}" "$tmp/backup/manifest.json" "$tmp/dump.sql" "$tmp/media.bin"; then
    echo "FAIL: the backup contains the value of $key" >&2
    exit 1
  fi
done
echo "no key value in the backup"
start=$SECONDS
PATH="$target_pg_bin:$PATH" "$tmp/bp" instance restore "$tmp/backup" --database-url "$target" --media-dir "$tmp/media-dst"
echo "restore took $((SECONDS - start))s"

echo "== boot the prod build against the TLS target with the same keys"
export DATABASE_URL="ecto://postgres@localhost:$port/barkpark" DATABASE_SSL=verify-full DATABASE_SSL_CA_FILE="$tmp/ca.crt"
(cd "$root/api" && PHX_SERVER=true PORT=$http_port exec mix phx.server >"$tmp/server.log" 2>&1) &
server_pid=$!
ready=
for _ in $(seq 1 90); do
  ready=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$http_port/readyz" || true)
  [ "$ready" = 200 ] && break
  sleep 2
done
curl -s "http://localhost:$http_port/readyz"; echo
if [ "$ready" != 200 ]; then
  tail -40 "$tmp/server.log" >&2
  echo "FAIL: /readyz answered ${ready:-nothing}" >&2
  exit 1
fi
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=

mix_step check
echo "PASS: moved instance is ready over verified TLS and reads its encrypted data"
