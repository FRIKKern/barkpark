// Copy to main.bicepparam and set the image. The secrets come from the
// environment, so this file never holds a secret. Generate them once and keep
// them in your password manager: a new SECRET_KEY_BASE logs everyone out, and a
// new cloak key or KEK makes stored encrypted fields unreadable.
//
//   export BARKPARK_PG_PASSWORD="$(openssl rand -hex 24)"
//   export BARKPARK_SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"
//   export BARKPARK_CLOAK_KEY="$(openssl rand -base64 32)"
//   export BARKPARK_KEK="$(openssl rand -base64 32)"
//   export BARKPARK_PREVIEW_JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
//   export BARKPARK_RELEASE_CAPTURE_HMAC_SECRET="$(openssl rand -base64 32)"
//   export BARKPARK_SEED_ADMIN_TOKEN="bp_admin_$(openssl rand -hex 24)"

using 'main.bicep'

param image = 'ghcr.io/frikkern/barkpark:0.2.28'

// Set when the image lives in an Azure Container Registry. Add
// acrResourceGroup when the registry sits in another resource group.
param acrName = ''

// Set when a custom domain points at the app.
param publicHost = ''

param postgresAdminPassword = readEnvironmentVariable('BARKPARK_PG_PASSWORD')
param secretKeyBase = readEnvironmentVariable('BARKPARK_SECRET_KEY_BASE')
param cloakKey = readEnvironmentVariable('BARKPARK_CLOAK_KEY')
param kek = readEnvironmentVariable('BARKPARK_KEK')
param previewJwtSecret = readEnvironmentVariable('BARKPARK_PREVIEW_JWT_SECRET')
param seedAdminToken = readEnvironmentVariable('BARKPARK_SEED_ADMIN_TOKEN')
param releaseCaptureHmacSecret = readEnvironmentVariable('BARKPARK_RELEASE_CAPTURE_HMAC_SECRET')
