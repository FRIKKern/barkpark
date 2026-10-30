// A container registry for Barkpark built from source (Path B from source).
//
// Deploy it on its own before main.bicep, build the image into it with
// `az acr build`, then deploy main.bicep with image=<registry>.azurecr.io/...
// and acrName=<registry>. main.bicep then gives the app's identity AcrPull.
// docs/setup/SELF-HOST.md#build-the-image-from-source has the commands.

targetScope = 'resourceGroup'

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Registry name, 5 to 50 letters and digits, globally unique.')
@minLength(5)
@maxLength(50)
param acrName string = 'crbarkpark${uniqueString(resourceGroup().id)}'

@description('Basic holds 10 GiB, enough for a few Barkpark images.')
@allowed(['Basic', 'Standard', 'Premium'])
param sku string = 'Basic'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: sku }
  properties: {
    // The app pulls with its managed identity, so no admin user.
    adminUserEnabled: false
  }
}

output acrName string = registry.name
output loginServer string = registry.properties.loginServer
