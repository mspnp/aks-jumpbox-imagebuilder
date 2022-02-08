targetScope = 'resourceGroup'

/*** PARAMETERS ***/

@description('Required. The resource ID of the Azure Image Builder service\'s user managed identity that needs to write the final image into this resource group.')
@minLength(80)
param aibManagedIdentityResourceId string

@description('Required. The resource ID of the role definition to be assigned to the managed identity to support the image writing process.')
@minLength(80)
param aibImageCreatorRoleDefinitionResourceId string

/*** RESOURCES ***/

@description('Grants AIB required permissions to write final jumpbox image in designated resource group.')
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(resourceGroup().id, aibManagedIdentityResourceId, aibImageCreatorRoleDefinitionResourceId)
  scope: resourceGroup()
  properties: {
    principalId: aibManagedIdentityResourceId
    roleDefinitionId: aibImageCreatorRoleDefinitionResourceId
    description: 'Grants AIB required permissions to write final jumpbox image in designated resource group.'
    principalType: 'ServicePrincipal'
  }
}
