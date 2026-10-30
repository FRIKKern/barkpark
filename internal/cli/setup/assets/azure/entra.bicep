// The Entra ID side of Barkpark sign-in, through the Microsoft Graph Bicep
// extension: the app registration with the redirect URI for the host, its
// service principal, the owners security group with its members, the groups,
// email and amr claims, and admin consent for openid, profile and email. It
// does what scripts/entra-app-register.sh does, except the client secret.
//
// main.bicep deploys it with entraEnabled=true. It also deploys on its own at
// resource group scope with only host and org, for a single VM:
//   az deployment group create -g <rg> -n barkpark-entra -f entra.bicep \
//     -p host=barkpark.example.com org=pensum
// The deploying user needs the Entra roles in docs/setup/IT-HANDOVER.md.
// Entra ID P1 is not needed with the default groupClaims.

extension microsoftGraphV1

targetScope = 'resourceGroup'

@description('Public host name of the Barkpark instance, no scheme. It is PHX_HOST.')
param host string

@description('Barkpark organization slug. It is part of the redirect URI.')
param org string

@description('Suffix that keeps the app and group apart from other instances in the tenant.')
param nameSuffix string = uniqueString(resourceGroup().id)

@description('App display name.')
param appName string = 'Barkpark ${org} (${host})'

@description('Owners security group display name.')
param ownersGroupName string = 'Barkpark ${org} owners (${host})'

@description('User principal names to add to the owners group.')
param ownerUpns array = []

@description('Add the user or service principal that runs the deployment to the owners group.')
param addDeployer bool = true

@description('SecurityGroup sends every security group of the user and works without Entra ID P1. ApplicationGroup sends only groups assigned to the app and needs P1. See ENTRA.md#users-in-many-groups.')
@allowed(['SecurityGroup', 'ApplicationGroup'])
param groupClaims string = 'SecurityGroup'

@description('Optional. A service principal object id that becomes an owner of the app and gets Application.ReadWrite.OwnedBy on Microsoft Graph, so it can add the client secret. main.bicep passes the identity of its secret script.')
param appOwnerPrincipalId string = ''

var graphAppId = '00000003-0000-0000-c000-000000000000'
// Microsoft Graph delegated scopes openid, profile and email.
var scopeIds = [
  '37f7f235-527c-4136-accd-4a02d197296e'
  '14dad69e-099b-42c9-810b-d002981feec1'
  '64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0'
]
// Microsoft Graph application permission Application.ReadWrite.OwnedBy.
var applicationReadWriteOwnedBy = '18a4783c-866b-4cc7-a460-3d5e5662c884'
var defaultAccess = '00000000-0000-0000-0000-000000000000'
var redirectUri = 'https://${host}/v1/auth/oidc/${org}/callback'
var hasAppOwner = !empty(appOwnerPrincipalId)

resource graph 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: graphAppId
}

resource owners 'Microsoft.Graph/users@v1.0' existing = [for upn in ownerUpns: {
  userPrincipalName: upn
}]

resource app 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: 'barkpark-${org}-${nameSuffix}'
  displayName: appName
  // Single tenant. The redirect is on the Web platform, because Barkpark
  // exchanges the code on the server with a client secret.
  signInAudience: 'AzureADMyOrg'
  web: {
    redirectUris: [redirectUri]
  }
  // Groups as object ids, and email and amr in the ID token. Barkpark reads
  // amr for trust_idp_mfa.
  groupMembershipClaims: groupClaims
  optionalClaims: {
    idToken: [
      { name: 'email', essential: false }
      { name: 'amr', essential: false }
    ]
    accessToken: []
    saml2Token: []
  }
  requiredResourceAccess: [
    {
      resourceAppId: graphAppId
      resourceAccess: [for id in scopeIds: { id: id, type: 'Scope' }]
    }
  ]
  owners: {
    relationships: hasAppOwner ? [appOwnerPrincipalId] : []
  }
}

// The enterprise app that users sign in to.
resource sp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: app.appId
}

// Admin consent, tenant wide, so no user sees a consent prompt.
resource consent 'Microsoft.Graph/oauth2PermissionGrants@v1.0' = {
  clientId: sp.id
  consentType: 'AllPrincipals'
  resourceId: graph.id
  scope: 'openid profile email'
}

resource ownersGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: 'barkpark-${org}-owners-${nameSuffix}'
  displayName: ownersGroupName
  mailEnabled: false
  mailNickname: 'barkpark-${org}-owners-${nameSuffix}'
  securityEnabled: true
  members: {
    // The owners by UPN, then the deploying principal.
    relationships: [for i in range(0, length(ownerUpns) + (addDeployer ? 1 : 0)): i < length(ownerUpns) ? owners[i].id : deployer().objectId]
  }
}

// With ApplicationGroup, Entra puts only groups assigned to the app in the token.
resource ownersAssigned 'Microsoft.Graph/appRoleAssignedTo@v1.0' = if (groupClaims == 'ApplicationGroup') {
  principalId: ownersGroup.id
  resourceId: sp.id
  appRoleId: defaultAccess
}

// Lets that owner add a password to the apps it owns, this one only.
resource ownerMayAddPasswords 'Microsoft.Graph/appRoleAssignedTo@v1.0' = if (hasAppOwner) {
  principalId: appOwnerPrincipalId
  resourceId: graph.id
  appRoleId: applicationReadWriteOwnedBy
}

output tenantId string = tenant().tenantId
output issuer string = '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
output clientId string = app.appId
output appObjectId string = app.id
output servicePrincipalId string = sp.id
output ownersGroupId string = ownersGroup.id
output redirectUri string = redirectUri
output signInUrl string = 'https://${host}/v1/auth/oidc/${org}/start'
