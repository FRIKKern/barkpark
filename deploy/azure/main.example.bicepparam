// Copy to main.bicepparam next to barkpark.env, the file that
// `bp instance init --target containerapps` writes, and set the image. This
// file reads the seven secrets and the settings from barkpark.env, so neither
// file goes into version control. The template uses only the password from
// DATABASE_URL and sets its own database host and BARKPARK_MEDIA_DIR, so any
// value works for those two placeholders, such as `unused`. Keep barkpark.env
// in your password manager: a new SECRET_KEY_BASE logs everyone out, and a new
// cloak key or KEK makes stored encrypted fields unreadable.

using 'main.bicep'

var lines = filter(split(loadTextContent('barkpark.env'), '\n'), l => !startsWith(trim(l), '#') && contains(l, '='))
var env = toObject(lines, l => trim(split(l, '=')[0]), l => trim(substring(l, indexOf(l, '=') + 1)))

param image = 'ghcr.io/frikkern/barkpark:0.2.28'

// Set when the image lives in an Azure Container Registry. Add
// acrResourceGroup when the registry sits in another resource group.
param acrName = ''

// Set when a custom domain points at the app.
param publicHost = ''

// Public addresses let through the Key Vault and storage firewalls, such as
// your laptop's for `az keyvault secret set` or copying backups. Postgres
// never gets one.
param operatorIpRanges = []

// To join an existing virtual network, set both subnets. See main.bicep for
// the delegation and service endpoints each needs.
param appsSubnetId = ''
param postgresSubnetId = ''

// DATABASE_URL is ecto://barkpark:<password>@<host>/barkpark.
param postgresAdminPassword = split(split(env.DATABASE_URL, '@')[0], ':')[2]
param secretKeyBase = env.SECRET_KEY_BASE
param cloakKey = env.BARKPARK_CLOAK_KEY
param kek = env.BARKPARK_KEK
param previewJwtSecret = env.PREVIEW_JWT_SECRET
param seedAdminToken = env.BARKPARK_SEED_ADMIN_TOKEN
param releaseCaptureHmacSecret = env.BARKPARK_RELEASE_CAPTURE_HMAC_SECRET
// Only a moved instance has these. Copy them from the source with
// BARKPARK_KEK_VERSION and BARKPARK_OPERATOR_TOKEN_IDS.
param kekPrevious = env.?BARKPARK_KEK_PREVIOUS ?? ''
param ingestToken = env.?BARKPARK_INGEST_TOKEN ?? ''

// true deploys everything but the app, for a restore into the empty database.
param restoreMode = false

// Every other line becomes a plain setting on the app and the jobs, and
// deployment history keeps it. Keep any further secret out of barkpark.env.
var secretNames = [
  'DATABASE_URL'
  'SECRET_KEY_BASE'
  'BARKPARK_CLOAK_KEY'
  'BARKPARK_KEK'
  'PREVIEW_JWT_SECRET'
  'BARKPARK_SEED_ADMIN_TOKEN'
  'BARKPARK_RELEASE_CAPTURE_HMAC_SECRET'
  'BARKPARK_KEK_PREVIOUS'
  'BARKPARK_INGEST_TOKEN'
]
param settings = toObject(filter(items(env), kv => !contains(secretNames, kv.key)), kv => kv.key, kv => kv.value)
