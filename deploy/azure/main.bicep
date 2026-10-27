// Barkpark on Azure Container Apps with one replica.
//
// One `az deployment group create` creates the whole setup in an empty
// resource group: Log Analytics, a Container Apps environment, the app,
// PostgreSQL Flexible Server 17, an Azure Files share for media, a Key Vault
// with the app's secrets and the user-assigned identity that reads them.
// main.example.bicepparam lists the parameters and how to generate each secret.

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

@description('Public host name. Leave empty to use the Container Apps default host name.')
param publicHost string = ''

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
@description('The first admin API token. Without it the first boot prints a generated token to the logs, which Log Analytics keeps. Generate with: echo "bp_admin_$(openssl rand -hex 24)"')
param seedAdminToken string

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
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
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
    network: { publicNetworkAccess: 'Enabled' }
  }
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

// 0.0.0.0 is Azure's marker for "connections from Azure services". The
// consumption environment has no fixed outbound address to list instead.
resource postgresFirewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgres
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
  dependsOn: [postgresDatabase]
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
  }
}

var secretValues = {
  'database-url': 'ecto://${postgresAdminLogin}:${uriComponent(postgresAdminPassword)}@${postgres.name}.postgres.database.azure.com/${databaseName}'
  'secret-key-base': secretKeyBase
  'cloak-key': cloakKey
  kek: kek
  'preview-jwt-secret': previewJwtSecret
  'seed-admin-token': seedAdminToken
  'release-capture-hmac-secret': releaseCaptureHmacSecret
}

resource vaultSecrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for item in items(secretValues): {
    parent: vault
    name: item.key
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
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
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

var host = empty(publicHost) ? '${appName}.${environment.properties.defaultDomain}' : publicHost

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    environmentId: environment.id
    configuration: {
      // One revision at a time: two live revisions would be two replicas.
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 4000
        transport: 'auto'
        allowInsecure: false
      }
      registries: empty(acrName) ? [] : [
        {
          server: '${acrName}.azurecr.io'
          identity: identity.id
        }
      ]
      secrets: [
        for item in items(secretValues): {
          name: item.key
          keyVaultUrl: '${vault.properties.vaultUri}secrets/${item.key}'
          identity: identity.id
        }
      ]
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
          env: [
            { name: 'DATABASE_URL', secretRef: 'database-url' }
            // Azure Postgres requires TLS. The image carries the CA roots.
            { name: 'DATABASE_SSL', value: 'verify-full' }
            { name: 'SECRET_KEY_BASE', secretRef: 'secret-key-base' }
            { name: 'BARKPARK_CLOAK_KEY', secretRef: 'cloak-key' }
            { name: 'BARKPARK_KEK', secretRef: 'kek' }
            { name: 'PREVIEW_JWT_SECRET', secretRef: 'preview-jwt-secret' }
            { name: 'BARKPARK_SEED_ADMIN_TOKEN', secretRef: 'seed-admin-token' }
            { name: 'BARKPARK_RELEASE_CAPTURE_HMAC_SECRET', secretRef: 'release-capture-hmac-secret' }
            { name: 'BARKPARK_SHAPE', value: 'solo' }
            { name: 'PHX_HOST', value: host }
            { name: 'PHX_SCHEME', value: 'https' }
            { name: 'BARKPARK_MEDIA_DIR', value: mediaPath }
          ]
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
          // SMB has no POSIX owners. These options make every file and
          // directory owned by the app user and writable by it.
          mountOptions: 'uid=${mediaUid},gid=${mediaUid},dir_mode=0770,file_mode=0660,mfsymlinks,nobrl'
        }
      ]
      // Barkpark runs on exactly one replica. See the README.
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
    postgresFirewall
  ]
}

output url string = 'https://${host}'
output defaultHost string = '${appName}.${environment.properties.defaultDomain}'
output postgresHost string = postgres.properties.fullyQualifiedDomainName
output keyVaultName string = vault.name
output identityClientId string = identity.properties.clientId
