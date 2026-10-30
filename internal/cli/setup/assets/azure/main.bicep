// Barkpark on Azure Container Apps with one replica.
//
// One `az deployment group create` creates the whole setup in an empty
// resource group: a virtual network, Log Analytics, a Container Apps
// environment, the app, two jobs, PostgreSQL Flexible Server 17, Azure Files
// shares for media and backups, a Key Vault with the app's secrets and the
// user-assigned identity that reads them. main.example.bicepparam reads the
// secrets and settings from the barkpark.env that bp instance init writes.
//
// Postgres has no public endpoint. It sits on a delegated subnet and answers
// only inside the virtual network, the way it listens only on localhost on a
// single VM. The Key Vault and the storage account accept the app subnet and
// the addresses in operatorIpRanges and refuse everyone else. Backup, restore
// and `bp instance check` run in the jobs barkpark-backup and barkpark-ops
// inside the same network.
//
// PHX_HOST is the app's Container Apps address, set in the same deployment,
// or customDomain from the first deployment on. The output dnsRecords lists
// the CNAME and asuid TXT records the domain needs; with bindCustomDomain the
// next deployment binds it with a managed certificate.

targetScope = 'resourceGroup'

@description('Azure region. Norway East is the target; Sweden Central is the fallback.')
param location string = resourceGroup().location

@description('Suffix for globally unique names. Change it to redeploy into a resource group whose Key Vault is still soft-deleted.')
@maxLength(13)
param nameSuffix string = uniqueString(resourceGroup().id)

@description('Container image, for example ghcr.io/frikkern/barkpark:0.2.28.')
param image string

@description('Name of an Azure Container Registry that holds the image. Leave empty for a public registry.')
param acrName string = ''

@description('Resource group of that registry. Defaults to this resource group.')
param acrResourceGroup string = resourceGroup().name

@description('Optional. Your own subdomain for the app, such as barkpark.example.com. It becomes PHX_HOST from the first deployment. The deployment prints the two DNS records it needs in the output dnsRecords.')
param customDomain string = ''

@description('Set true once the dnsRecords exist, and keep it. The deployment then binds customDomain with a free managed certificate.')
param bindCustomDomain bool = false

@description('vCPU for the app container.')
param cpu string = '1.0'

@description('Memory for the app container. Must match the vCPU ratio, 2Gi per vCPU.')
param memory string = '2Gi'

@description('UID and GID that own the media mount. The image runs as 10001.')
param mediaUid int = 10001

@description('Postgres compute size. Standard_B1ms is the smallest that runs Barkpark.')
param postgresSku string = 'Standard_B1ms'

@description('Postgres storage in GiB.')
param postgresStorageGb int = 32

param postgresAdminLogin string = 'barkpark'

@description('Address space of the virtual network the template creates. Ignored when both subnet IDs below are set.')
param vnetAddressPrefix string = '10.40.0.0/16'

@description('Optional. An existing subnet for the Container Apps environment, at least /27, delegated to Microsoft.App/environments, with the Microsoft.Storage and Microsoft.KeyVault service endpoints. Set it together with postgresSubnetId.')
param appsSubnetId string = ''

@description('Optional. An existing empty subnet in the same virtual network, delegated to Microsoft.DBforPostgreSQL/flexibleServers.')
param postgresSubnetId string = ''

@description('Optional. An existing private DNS zone whose name ends in .postgres.database.azure.com and that is linked to the virtual network. Leave empty to create one here.')
param postgresPrivateDnsZoneId string = ''

@description('Non-secret settings for the app and the jobs, such as the Pensum settings. main.example.bicepparam reads them from barkpark.env. Names the template sets itself are ignored.')
param settings object = {}

@description('Public IP addresses or CIDR ranges allowed through the Key Vault and storage firewalls, for an operator who sets secrets or copies backups from a laptop. Postgres never gets one.')
param operatorIpRanges array = []

@description('The bp CLI release the jobs install. 1.26.2 and newer restore into a newer Postgres major.')
param bpCliVersion string = '1.26.10'

@description('Create the Entra ID sign-in in this deployment with entra.bicep: the app registration, its service principal, the owners group, admin consent and a client secret in the Key Vault. The app then connects entraOrg at its first boot. Off by default. The deploying user needs the Entra roles in IT-HANDOVER.md.')
param entraEnabled bool = false

@description('With entraEnabled: the Barkpark organization slug. It is part of the redirect URI.')
param entraOrg string = ''

@description('With entraEnabled: the organization name Barkpark shows. Defaults to the slug.')
param entraOrgName string = ''

@description('With entraEnabled: user principal names to add to the owners group.')
param entraOwnerUpns array = []

@description('With entraEnabled: add the user who runs the deployment to the owners group.')
param entraAddDeployer bool = true

@description('With entraEnabled: SecurityGroup works without Entra ID P1. ApplicationGroup needs P1. See ENTRA.md#users-in-many-groups.')
@allowed(['SecurityGroup', 'ApplicationGroup'])
param entraGroupClaims string = 'SecurityGroup'

@description('With entraEnabled: count Entra MFA as Barkpark MFA (trust_idp_mfa). ENTRA.md#entra-mfa-counts-as-barkpark-mfa says how to check it.')
param entraTrustIdpMfa bool = true

@description('With entraEnabled: client secret lifetime in years.')
@allowed([1, 2])
param entraSecretYears int = 1

@description('Daily backup time for the job barkpark-backup, as a UTC cron expression.')
param backupCron string = '30 2 * * *'

@description('Days to keep backups on the backups share.')
param backupRetentionDays int = 14

@secure()
@description('Postgres admin password. Generate with: openssl rand -hex 24')
param postgresAdminPassword string

@secure()
@description('At least 64 bytes. Generate with: openssl rand -base64 64 | tr -d "\\n"')
param secretKeyBase string

@secure()
@description('Generate with: openssl rand -base64 32')
param cloakKey string

@secure()
@description('Base64 of 32 random bytes, independent of the cloak key. Generate with: openssl rand -base64 32')
param kek string

@secure()
@description('Generate with: openssl rand -base64 48')
param previewJwtSecret string

@secure()
@description('At least 32 bytes. A migration refuses to run without it. Generate with: openssl rand -base64 32')
param releaseCaptureHmacSecret string

@secure()
@description('Optional. The previous KEK of a moved instance whose data keys are still wrapped under it. Set BARKPARK_KEK_VERSION in settings to match the source.')
param kekPrevious string = ''

@secure()
@description('Optional. BARKPARK_INGEST_TOKEN of a moved instance.')
param ingestToken string = ''

@description('Deploy everything except the app, so barkpark-ops can restore a backup into the empty database before the first boot migrates it. Deploy again with false to start the app.')
param restoreMode bool = false

@secure()
@description('The first admin API token. Without it the first boot prints a generated token to the logs, which Log Analytics keeps. Generate with: echo "bp_admin_$(openssl rand -hex 24)"')
param seedAdminToken string

@description('Address that gets the alert mail from monitor.bicep: /readyz down, a failed backup job, repeated restarts. Empty deploys no alerts.')
param alertEmail string = ''

@description('Seconds between /readyz availability checks, 300 or 900. SELF-HOST-OPERATIONS.md#container-apps-alerts has the cost of each.')
@allowed([300, 900])
param availabilityFrequencySeconds int = 300

@description('Days the Log Analytics workspace keeps logs.')
param logRetentionDays int = 30

var appName = 'barkpark'
var databaseName = 'barkpark'
// The image's entrypoint refuses to start when this path is not writable.
var mediaPath = '/app/uploads'

// Built-in role definition IDs.
var keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-barkpark-${nameSuffix}'
  location: location
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-barkpark-${nameSuffix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logRetentionDays
    workspaceCapping: { dailyQuotaGb: 1 }
  }
}

// ── Network ─────────────────────────────────────────────────────────────────

var useExistingNetwork = !empty(appsSubnetId) && !empty(postgresSubnetId)

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = if (!useExistingNetwork) {
  name: 'vnet-barkpark-${nameSuffix}'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [vnetAddressPrefix] }
    subnets: [
      {
        // A workload profiles environment needs at least /27, delegated to
        // Microsoft.App/environments. /24 leaves room for job replicas.
        name: 'apps'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 24, 0)
          delegations: [
            { name: 'apps', properties: { serviceName: 'Microsoft.App/environments' } }
          ]
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
            { service: 'Microsoft.KeyVault' }
          ]
        }
      }
      {
        name: 'postgres'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 27, 8)
          delegations: [
            { name: 'postgres', properties: { serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers' } }
          ]
        }
      }
    ]
  }
}

var appsSubnet = useExistingNetwork ? appsSubnetId : '${vnet.id}/subnets/apps'
var postgresSubnet = useExistingNetwork ? postgresSubnetId : '${vnet.id}/subnets/postgres'
// A subnet ID is the virtual network ID plus /subnets/<name>.
var vnetId = join(take(split(appsSubnet, '/'), 9), '/')

resource postgresDns 'Microsoft.Network/privateDnsZones@2024-06-01' = if (empty(postgresPrivateDnsZoneId)) {
  name: 'barkpark-${nameSuffix}.private.postgres.database.azure.com'
  location: 'global'
}

resource postgresDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(postgresPrivateDnsZoneId)) {
  parent: postgresDns
  name: 'barkpark'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

// ── Postgres ────────────────────────────────────────────────────────────────

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'psql-barkpark-${nameSuffix}'
  location: location
  sku: {
    name: postgresSku
    tier: 'Burstable'
  }
  properties: {
    version: '17'
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    storage: { storageSizeGB: postgresStorageGb }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: { mode: 'Disabled' }
    // Private access: the server gets an address on the delegated subnet and
    // an A record in the private zone. The public name is a CNAME into that
    // zone, which resolves only inside the linked network.
    network: {
      publicNetworkAccess: 'Disabled'
      delegatedSubnetResourceId: postgresSubnet
      privateDnsZoneArmResourceId: empty(postgresPrivateDnsZoneId) ? postgresDns.id : postgresPrivateDnsZoneId
    }
  }
  dependsOn: [postgresDnsLink]
}

// Azure refuses CREATE EXTENSION for anything not on this list. The first
// migration creates citext, pg_trgm and pgcrypto, so the list must be in place
// before the app starts.
resource postgresExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgres
  name: 'azure.extensions'
  properties: {
    value: 'CITEXT,PG_TRGM,PGCRYPTO'
    source: 'user-override'
  }
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [postgresExtensions]
}

// ── Media share ─────────────────────────────────────────────────────────────

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stbarkpark${nameSuffix}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [{ id: appsSubnet, action: 'Allow' }]
      ipRules: [for ip in operatorIpRanges: { value: ip, action: 'Allow' }]
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource mediaShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'media'
  properties: {
    shareQuota: 100
    accessTier: 'TransactionOptimized'
  }
}

// bp instance backup writes here, one directory per run.
resource backupShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'backups'
  properties: {
    shareQuota: 100
    accessTier: 'TransactionOptimized'
  }
}

// ── Secrets ─────────────────────────────────────────────────────────────────

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-bp-${nameSuffix}'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [{ id: appsSubnet, ignoreMissingVnetServiceEndpoint: false }]
      ipRules: [for ip in operatorIpRanges: { value: ip }]
    }
  }
}

// Each secret lives in Key Vault and reaches the containers through a secret
// reference. Optional ones are left out when empty.
var secretTable = [
  { env: 'DATABASE_URL', name: 'database-url', value: 'ecto://${postgresAdminLogin}:${uriComponent(postgresAdminPassword)}@${postgres.name}.postgres.database.azure.com/${databaseName}' }
  { env: 'SECRET_KEY_BASE', name: 'secret-key-base', value: secretKeyBase }
  { env: 'BARKPARK_CLOAK_KEY', name: 'cloak-key', value: cloakKey }
  { env: 'BARKPARK_KEK', name: 'kek', value: kek }
  { env: 'BARKPARK_KEK_PREVIOUS', name: 'kek-previous', value: kekPrevious }
  { env: 'PREVIEW_JWT_SECRET', name: 'preview-jwt-secret', value: previewJwtSecret }
  { env: 'BARKPARK_SEED_ADMIN_TOKEN', name: 'seed-admin-token', value: seedAdminToken }
  { env: 'BARKPARK_RELEASE_CAPTURE_HMAC_SECRET', name: 'release-capture-hmac-secret', value: releaseCaptureHmacSecret }
  { env: 'BARKPARK_INGEST_TOKEN', name: 'ingest-token', value: ingestToken }
]
var secretItems = filter(secretTable, item => !empty(item.value))

resource vaultSecrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for item in secretItems: {
    parent: vault
    name: item.name
    properties: { value: item.value }
  }
]

resource identityReadsSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, identity.id, keyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

module identityPullsImages 'acr-pull.bicep' = if (!empty(acrName)) {
  name: 'acr-pull-${nameSuffix}'
  scope: resourceGroup(acrResourceGroup)
  params: {
    acrName: acrName
    principalId: identity.properties.principalId
  }
}

// ── Container Apps ──────────────────────────────────────────────────────────

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-barkpark-${nameSuffix}'
  location: location
  properties: {
    // The Consumption profile bills like a consumption-only environment and
    // has no management charge. It is what lets the environment join a /27.
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    vnetConfiguration: {
      infrastructureSubnetId: appsSubnet
      internal: false
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource environmentBackups 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: environment
  name: 'backups'
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: backupShare.name
      accessMode: 'ReadWrite'
    }
  }
}

resource environmentMedia 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: environment
  name: 'media'
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: mediaShare.name
      accessMode: 'ReadWrite'
    }
  }
}

// PHX_HOST is the custom domain when set, else the app's default address,
// which Azure knows once the environment exists in this same deployment.
// main.example.bicepparam reads customDomain from PHX_HOST in barkpark.env.
var defaultHost = '${appName}.${environment.properties.defaultDomain}'
// A name under azurecontainerapps.io is Azure's own address, not a custom domain.
var hasCustomDomain = !empty(customDomain) && !endsWith(toLower(customDomain), '.azurecontainerapps.io')
var host = hasCustomDomain ? toLower(customDomain) : defaultHost
// The address that serves HTTPS now: the custom domain only once it is bound.
var liveHost = hasCustomDomain && bindCustomDomain ? host : defaultHost

// The instance's own origin goes first on BARKPARK_ALWAYS_ALLOWED_ORIGINS,
// followed by the origins in barkpark.env, so the list follows PHX_HOST.
var extraOrigins = filter(
  map(split(string(settings.?BARKPARK_ALWAYS_ALLOWED_ORIGINS ?? ''), ','), o => trim(o)),
  o => !empty(o) && o != 'https://${host}'
)
var allowedOrigins = join(concat(['https://${host}'], extraOrigins), ',')

// ── Entra ID ────────────────────────────────────────────────────────────────

// With entraEnabled, entra.bicep creates the Entra app for host, and a
// deployment script adds its client secret straight into the Key Vault. The
// Graph extension cannot add a password: Entra generates it in the addPassword
// action, which a declarative resource does not call. The script runs as its
// own identity, which owns the app and holds Application.ReadWrite.OwnedBy,
// and writes through Azure Resource Manager, so the vault firewall stays shut.
// The secret is never in a parameter, an output or a log. A redeploy keeps the
// secret that is in the vault. The app then reads it like its other secrets,
// and Barkpark.Sso.OidcBootstrap connects entraOrg at the first boot.
var keyVaultContributor = 'f25e0fa2-a7c8-4377-a976-54943a77a395'
var oidcSecretName = 'oidc-client-secret'
var oidcExpiresName = 'oidc-client-secret-expires-at'

resource entraScriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (entraEnabled) {
  name: 'id-barkpark-entra-${nameSuffix}'
  location: location
}

module entra 'entra.bicep' = if (entraEnabled) {
  name: 'entra-${nameSuffix}'
  params: {
    host: host
    org: entraOrg
    nameSuffix: nameSuffix
    ownerUpns: entraOwnerUpns
    addDeployer: entraAddDeployer
    groupClaims: entraGroupClaims
    appOwnerPrincipalId: entraScriptIdentity!.properties.principalId
  }
}

// Writing a secret through Resource Manager is a Key Vault Contributor action.
resource entraScriptWritesSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (entraEnabled) {
  scope: vault
  name: guid(vault.id, 'id-barkpark-entra-${nameSuffix}', keyVaultContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultContributor)
    principalId: entraScriptIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

var entraSecretScript = '''
set -eu
uri="${ARM_URL%/}${VAULT_ID}/secrets"
api="api-version=2023-07-01"
if az rest --method get --uri "$uri/$SECRET_NAME?$api" -o none 2>/dev/null; then
  echo "Key Vault holds $SECRET_NAME already. No new client secret."
  exit 0
fi
umask 077
dir=$(mktemp -d)
end=$(date -u -d "+$YEARS years" +%Y-%m-%dT%H:%M:%SZ)
# A new identity's Graph permission can take some minutes to reach its token.
for try in $(seq 1 20); do
  if az ad app credential reset --id "$APP_ID" --append --display-name "$CREDENTIAL_NAME" \
    --end-date "$end" --query password -o tsv >"$dir/value" 2>"$dir/err"; then
    break
  fi
  rm -f "$dir/value"
  echo "Graph refused the client secret, try $try: $(grep -m1 ERROR "$dir/err" | cut -c1-200)"
  sleep 30
done
[ -s "$dir/value" ] || { echo "No client secret after 20 tries" >&2; exit 1; }
jq -n --rawfile v "$dir/value" --argjson exp "$(date -u -d "$end" +%s)" \
  '{properties: {value: ($v | rtrimstr("\n")), attributes: {exp: $exp}}}' >"$dir/body"
az rest --method put --uri "$uri/$SECRET_NAME?$api" --body "@$dir/body" -o none
jq -n --arg v "$end" '{properties: {value: $v}}' >"$dir/body"
az rest --method put --uri "$uri/$EXPIRES_NAME?$api" --body "@$dir/body" -o none
rm -rf "$dir"
echo "Key Vault holds the new client secret as $SECRET_NAME. It expires $end."
'''

resource entraSecret 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (entraEnabled) {
  name: 'entra-secret-${nameSuffix}'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${entraScriptIdentity.id}': {} }
  }
  properties: {
    azCliVersion: '2.67.0'
    scriptContent: entraSecretScript
    environmentVariables: [
      { name: 'APP_ID', value: entra!.outputs.clientId }
      { name: 'VAULT_ID', value: vault.id }
      { name: 'ARM_URL', value: az.environment().resourceManager }
      { name: 'SECRET_NAME', value: oidcSecretName }
      { name: 'EXPIRES_NAME', value: oidcExpiresName }
      { name: 'CREDENTIAL_NAME', value: 'barkpark-${entraOrg}' }
      { name: 'YEARS', value: string(entraSecretYears) }
    ]
    timeout: 'PT30M'
    retentionInterval: 'PT1H'
    cleanupPreference: 'Always'
  }
  dependsOn: [
    entraScriptWritesSecrets
  ]
}

// The app reads both from Key Vault. The jobs do not need them.
var entraSecretNames = entraEnabled ? [oidcSecretName, oidcExpiresName] : []
var entraSecrets = [
  for name in entraSecretNames: {
    name: name
    keyVaultUrl: 'https://${vault.name}${az.environment().suffixes.keyvaultDns}/secrets/${name}'
    identity: identity.id
  }
]

var entraEnv = entraEnabled ? [
  { name: 'BARKPARK_OIDC_BOOTSTRAP_ORG', value: entraOrg }
  { name: 'BARKPARK_OIDC_BOOTSTRAP_ORG_NAME', value: empty(entraOrgName) ? entraOrg : entraOrgName }
  { name: 'BARKPARK_OIDC_BOOTSTRAP_ISSUER', value: entra!.outputs.issuer }
  { name: 'BARKPARK_OIDC_BOOTSTRAP_CLIENT_ID', value: entra!.outputs.clientId }
  { name: 'BARKPARK_OIDC_BOOTSTRAP_TENANT_ID', value: entra!.outputs.tenantId }
  { name: 'BARKPARK_OIDC_BOOTSTRAP_OWNER_GROUP', value: entra!.outputs.ownersGroupId }
  { name: 'BARKPARK_OIDC_BOOTSTRAP_TRUST_IDP_MFA', value: entraTrustIdpMfa ? 'on' : 'off' }
  { name: 'BARKPARK_OIDC_BOOTSTRAP_CLIENT_SECRET', secretRef: oidcSecretName }
  { name: 'BARKPARK_OIDC_BOOTSTRAP_CLIENT_SECRET_EXPIRES_AT', secretRef: oidcExpiresName }
] : []

var appSecrets = [
  for item in secretItems: {
    name: item.name
    // vaultUri is only known after deployment, and a for-body needs a value now.
    keyVaultUrl: 'https://${vault.name}${az.environment().suffixes.keyvaultDns}/secrets/${item.name}'
    identity: identity.id
  }
]

// Settings the template owns. A copy in `settings` is dropped, because a name
// may appear only once in a container's environment.
var ownedSettings = concat(map(secretTable, item => item.env), [
  'DATABASE_SSL'
  'BARKPARK_SHAPE'
  'BARKPARK_IMAGE'
  'PHX_HOST'
  'PHX_SCHEME'
  'BARKPARK_MEDIA_DIR'
  'BARKPARK_ALWAYS_ALLOWED_ORIGINS'
  'BARKPARK_OIDC_BOOTSTRAP_ORG'
  'BARKPARK_OIDC_BOOTSTRAP_ORG_NAME'
  'BARKPARK_OIDC_BOOTSTRAP_ISSUER'
  'BARKPARK_OIDC_BOOTSTRAP_CLIENT_ID'
  'BARKPARK_OIDC_BOOTSTRAP_TENANT_ID'
  'BARKPARK_OIDC_BOOTSTRAP_OWNER_GROUP'
  'BARKPARK_OIDC_BOOTSTRAP_TRUST_IDP_MFA'
  'BARKPARK_OIDC_BOOTSTRAP_CLIENT_SECRET'
  'BARKPARK_OIDC_BOOTSTRAP_CLIENT_SECRET_EXPIRES_AT'
])

// ENTRA.md lists these two settings for an Entra connection. A value in
// settings wins.
var entraSettings = entraEnabled ? {
  BARKPARK_OIDC_KEEP_OWNER: 'on'
  BARKPARK_OIDC_EMAIL_FROM_UPN: 'on'
} : {}

var settingsEnv = map(
  filter(items(union(entraSettings, settings)), kv => !contains(ownedSettings, kv.key)),
  kv => { name: kv.key, value: string(kv.value) }
)

var appEnv = concat(settingsEnv, map(secretItems, item => { name: item.env, secretRef: item.name }), [
  // Azure Postgres requires TLS. The image carries the CA roots.
  { name: 'DATABASE_SSL', value: 'verify-full' }
  { name: 'BARKPARK_SHAPE', value: 'solo' }
  // /status.json reports it as `image`, so the pinned tag is visible.
  { name: 'BARKPARK_IMAGE', value: image }
  { name: 'PHX_HOST', value: host }
  { name: 'PHX_SCHEME', value: 'https' }
  { name: 'BARKPARK_MEDIA_DIR', value: mediaPath }
  { name: 'BARKPARK_ALWAYS_ALLOWED_ORIGINS', value: allowedOrigins }
])

// SMB has no POSIX owners. These options make every file and directory owned
// by the app user and writable by it.
var mediaMountOptions = 'uid=${mediaUid},gid=${mediaUid},dir_mode=0770,file_mode=0660,mfsymlinks,nobrl'

resource app 'Microsoft.App/containerApps@2025-07-01' = if (!restoreMode) {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      // One revision at a time: two live revisions would be two replicas.
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 4000
        transport: 'auto'
        allowInsecure: false
        // Auto binds the managed certificate below once it is issued. Adding
        // the name fails until the CNAME and asuid TXT records resolve.
        customDomains: hasCustomDomain && bindCustomDomain ? [
          { name: host, bindingType: 'Auto' }
        ] : []
      }
      registries: empty(acrName) ? [] : [
        {
          server: '${acrName}.azurecr.io'
          identity: identity.id
        }
      ]
      secrets: concat(appSecrets, entraSecrets)
    }
    template: {
      containers: [
        {
          name: 'barkpark'
          image: image
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: concat(appEnv, entraEnv)
          volumeMounts: [
            { volumeName: 'media', mountPath: mediaPath }
          ]
          probes: [
            // Migrations run before the server listens, so the startup probe
            // allows about five minutes on a fresh database.
            {
              type: 'Startup'
              httpGet: { path: '/livez', port: 4000 }
              initialDelaySeconds: 10
              periodSeconds: 30
              failureThreshold: 10
            }
            {
              type: 'Liveness'
              httpGet: { path: '/livez', port: 4000 }
              periodSeconds: 30
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/readyz', port: 4000 }
              periodSeconds: 10
              failureThreshold: 3
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'media'
          storageType: 'AzureFile'
          storageName: environmentMedia.name
          mountOptions: mediaMountOptions
        }
      ]
      // Barkpark runs on exactly one replica. See docs/setup/SELF-HOST-UPDATES.md#container-apps.
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    identityReadsSecrets
    identityPullsImages
    vaultSecrets
    postgresDatabase
    entraSecret
  ]
}

// A free certificate from DigiCert, validated through the CNAME. It renews
// itself while the CNAME points at the app and the app runs.
resource certificate 'Microsoft.App/managedEnvironments/managedCertificates@2025-07-01' = if (hasCustomDomain && bindCustomDomain && !restoreMode) {
  parent: environment
  name: 'mc-${appName}-${nameSuffix}'
  location: location
  properties: {
    subjectName: host
    domainControlValidation: 'CNAME'
  }
  dependsOn: [
    app
  ]
}

// ── Operations jobs ─────────────────────────────────────────────────────────

// Two jobs run bp and the Postgres 17 client tools inside the network, with
// the app's settings, the media share at the same path and the backups share
// at /backups. barkpark-backup runs `backup` on backupCron and on demand.
// barkpark-ops runs only when started and takes its operation from its args:
//   backup | check | list | restore <backup dir> [<database> [<media dir>]]
// Set them with `az containerapp job update --args`. An override on
// `az containerapp job start` replaces the whole container and drops the
// command, settings and mounts. SELF-HOST-OPERATIONS.md has the commands.
var opsScript = '''
set -eu
apk add --no-cache -q postgresql17-client curl >/dev/null
curl -fsSL "https://raw.githubusercontent.com/FRIKKern/barkpark/cli-v$BP_CLI_VERSION/scripts/install-cli.sh" \
  | BARKPARK_CLI_VERSION="$BP_CLI_VERSION" BARKPARK_BIN_DIR=/usr/local/bin sh >/dev/null
# DATABASE_URL is ecto://user:pass@host/db. libpq wants postgresql:// and the TLS mode.
base="postgresql://${DATABASE_URL#ecto://}"
base="${base%/*}"
url() { echo "$base/$1?sslmode=verify-full&sslrootcert=system"; }
op="${1:-backup}"
case "$op" in
  backup)
    out="/backups/$(date -u +%Y%m%dT%H%M%SZ)"
    bp instance backup --database-url "$(url barkpark)" --media-dir "$BARKPARK_MEDIA_DIR" --out "$out"
    find /backups -mindepth 1 -maxdepth 1 -type d -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf {} +
    ;;
  restore)
    bp instance restore "/backups/$2" --database-url "$(url "${3:-barkpark}")" --media-dir "${4:-$BARKPARK_MEDIA_DIR}"
    ;;
  check) bp instance check --target containerapps ;;
  list) ls -l /backups ;;
  *) echo "unknown operation $op: use backup, check, list or restore" >&2; exit 2 ;;
esac
'''

var jobs = [
  {
    name: '${appName}-backup'
    args: ['backup']
    triggerType: 'Schedule'
    scheduleTriggerConfig: {
      cronExpression: backupCron
      parallelism: 1
      replicaCompletionCount: 1
    }
    manualTriggerConfig: null
  }
  {
    name: '${appName}-ops'
    args: ['check']
    triggerType: 'Manual'
    scheduleTriggerConfig: null
    manualTriggerConfig: {
      parallelism: 1
      replicaCompletionCount: 1
    }
  }
]

resource opsJobs 'Microsoft.App/jobs@2024-03-01' = [for job in jobs: {
  name: job.name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: job.triggerType
      scheduleTriggerConfig: job.scheduleTriggerConfig
      manualTriggerConfig: job.manualTriggerConfig
      replicaTimeout: 3600
      replicaRetryLimit: 0
      secrets: appSecrets
    }
    template: {
      containers: [
        {
          name: 'ops'
          image: 'public.ecr.aws/docker/library/alpine:3.22'
          command: ['/bin/sh', '-c', opsScript, 'ops']
          args: job.args
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: concat(appEnv, [
            { name: 'BP_CLI_VERSION', value: bpCliVersion }
            { name: 'BACKUP_RETENTION_DAYS', value: string(backupRetentionDays) }
          ])
          volumeMounts: [
            { volumeName: 'media', mountPath: mediaPath }
            { volumeName: 'backups', mountPath: '/backups' }
          ]
        }
      ]
      volumes: [
        {
          name: 'media'
          storageType: 'AzureFile'
          storageName: environmentMedia.name
          mountOptions: mediaMountOptions
        }
        {
          name: 'backups'
          storageType: 'AzureFile'
          storageName: environmentBackups.name
          mountOptions: mediaMountOptions
        }
      ]
    }
  }
  dependsOn: [
    identityReadsSecrets
    vaultSecrets
  ]
}]

// ── Alerts ──────────────────────────────────────────────────────────────────

// Mail on /readyz down, a failed backup job and repeated restarts. It runs
// after the jobs, because the backup alert needs the job.
module monitor 'monitor.bicep' = if (!empty(alertEmail) && !restoreMode) {
  name: 'monitor-${nameSuffix}'
  params: {
    location: location
    nameSuffix: nameSuffix
    logAnalyticsWorkspaceId: logs.id
    containerAppId: app.id
    publicHost: liveHost
    backupJobName: jobs[0].name
    alertEmail: alertEmail
    availabilityFrequencySeconds: availabilityFrequencySeconds
  }
  dependsOn: [
    opsJobs
  ]
}

// PHX_HOST. The Entra redirect URI is https://<host>/v1/auth/oidc/<org>/callback.
output host string = host
output url string = 'https://${host}'
output defaultHost string = defaultHost
// The records to create at your DNS provider before bindCustomDomain=true.
output dnsRecords array = hasCustomDomain ? [
  { type: 'CNAME', name: host, value: defaultHost }
  { type: 'TXT', name: 'asuid.${host}', value: environment.properties.customDomainConfiguration.customDomainVerificationId }
] : []
output postgresHost string = postgres.properties.fullyQualifiedDomainName
output storageAccountName string = storage.name
output keyVaultName string = vault.name
output identityClientId string = identity.properties.clientId
// With entraEnabled: the Entra app and the organization's sign-in URL. The
// client secret is in the Key Vault as oidc-client-secret, never an output.
output entraTenantId string = entraEnabled ? entra!.outputs.tenantId : ''
output entraClientId string = entraEnabled ? entra!.outputs.clientId : ''
output entraOwnersGroupId string = entraEnabled ? entra!.outputs.ownersGroupId : ''
output entraRedirectUri string = entraEnabled ? entra!.outputs.redirectUri : ''
output entraSignInUrl string = entraEnabled ? entra!.outputs.signInUrl : ''
