targetScope = 'resourceGroup'

/*** PARAMETERS ***/

@description('Required. The location of the Virtual Network in which image builds will take place.')
@minLength(1)
param location string

@description('Optional. Set the output name for the image template resource, needs to be unique within the resource group.')
@minLength(1)
param imageTemplateName string = 'imgt-askopsjb-${utcNow('yyyyMMddTHHmmss')}'

@description('Required. The subnet name found within the designated Virtual Network in which image builds will take place.')
@minLength(120)
param existingSubnetResourceId string

@description('The name of the exisiting Resource Group in which the managed VM image resource will be deployed to. It can be the same as this deployment\'s Resource Group and/or the vnet Resource Group.')
@minLength(1)
param imageDestinationResourceGroupName string

@description('Optional. Set the output name for the managed VM image resource.')
@minLength(1)
param imageName string = 'img-aksopsjb-${utcNow('yyyyMMddTHHmmss')}'

@description('Required. Ideally the custom Azure Image Builder Service Network Joiner role, otherwise should be Network Contributor role guid.')
@minLength(36)
@maxLength(36)
param imageBuilderNetworkingRoleGuid string

@description('Required. Ideally the custom Image Contributor role, otherwise should be Contributor role guid.')
@minLength(36)
@maxLength(36)
param imageBuilderImageCreationRoleGuid string

/*** EXISTING RESOURCES ***/

@description('The resource group name containing virtual network in which Azure Image Builder will drop the compute into to perform the image build.')
resource rgBuilderVirutalNetwork 'Microsoft.Resources/resourceGroups@2021-04-01' existing = {
  scope: subscription()
  name: split(existingSubnetResourceId, '/')[4]
}

@description('The virtual network in which Azure Image Builder will drop the compute into to perform the image build.')
resource vnetBuilder 'Microsoft.Network/virtualNetworks@2021-05-01' existing = {
  scope: rgBuilderVirutalNetwork
  name: split(existingSubnetResourceId, '/')[8]

  resource buildSubnet 'subnets@2021-05-01' existing = {
    name: last(split(existingSubnetResourceId, '/'))
  }
}

@description('The role to be assigned to the Azure Image Builder service that needs enough permission to join compute to a subnet.')
resource imageBuilderNetworkingRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: imageBuilderNetworkingRoleGuid
}

@description('The role to be assigned to the Azure Image Builder service that needs enough permission to write a virtual machine image.')
resource imageBuilderImageCreationRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: imageBuilderImageCreationRoleGuid
}

@description('The resource gorup that will be the destination for the virtual machine image.')
resource rgImageDestination 'Microsoft.Resources/resourceGroups@2021-04-01' existing = {
  scope: subscription()
  name: imageDestinationResourceGroupName
}

/*** EXISTING RESOURCES ***/

@description('Azure Image Builder (AIB) executes as this identity.')
resource aibUserManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: 'mi-aks-jumpbox-imagebuilder-${uniqueString(resourceGroup().id)}'
  location: location
}

@description('Grants the managed identity the ability to write the generated image into the destination resource group.')
module applyAibImageWriterRoleToDestinationRg 'modules/aibImageWriteRoleAssignment.bicep' = {
  name: 'applyAibImageWriterRoleToDestinationRg'
  scope: rgImageDestination
  params: {
    aibImageCreatorRoleDefinitionResourceId: imageBuilderImageCreationRoleDefinition.id
    aibManagedIdentityPrincipalId: aibUserManagedIdentity.properties.principalId
  }
}

@description('Grants the managed identity the ability to join the image building compute into the destinated subnet.')
module applyAibNetworkingRoleToBuilderVirtualNetwork 'modules/aibNetworkRoleAssignment.bicep' = {
  name: 'applyAibNetworkRoleToVnet'
  scope: rgBuilderVirutalNetwork
  params: {
    aibManagedIdentityPrincipalId: aibUserManagedIdentity.properties.principalId
    aibNetworkRoleDefinitionResourceId: imageBuilderNetworkingRoleDefinition.id
    targetVirtualNetworkName: vnetBuilder.name
  }
}

@description('This is the image spec for our general purpose AKS jump box. This template can be used to build VM images as needed.')
resource imgtJumpBoxSpec 'Microsoft.VirtualMachineImages/imageTemplates@2021-10-01' = {
  name: imageTemplateName
  location: location
  dependsOn: [
    applyAibImageWriterRoleToDestinationRg
    applyAibNetworkingRoleToBuilderVirtualNetwork
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aibUserManagedIdentity.id}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: 60
    vmProfile: {
      osDiskSizeGB: 32
      vmSize: 'Standard_D2ds_v4'
      vnetConfig: {
        subnetId: vnetBuilder::buildSubnet.id
        proxyVmSize: 'Standard_D2ds_v4'
      }
    }
    source: {
      type: 'PlatformImage'
      publisher: 'Canonical'
      offer: 'UbuntuServer'
      sku: '18_04-lts-gen2'
      version: 'latest'
    }
    distribute: [
      {
        type: 'ManagedImage'
        runOutputName: 'managedImageTarget'
        location: location
        imageId: resourceId(imageDestinationResourceGroupName, 'Microsoft.Compute/images', imageName)
      }
    ]
    customize: [
      {
        type: 'Shell'
        name: 'Update Installed Packages'
        inline: [
          'echo "Starting "apt-get update/upgrade"'
          'sudo apt-get -yq update'
          '#sudo apt-get -yq upgrade'
          'echo "Completed "apt-get update/ugrade"'
        ]
      }
      {
        type: 'Shell'
        name: 'Adjust sshd settings.'
        inline: [
          'echo "Starting "sshd settings changes"'
          'sudo sed -i \'s:^#\\?X11Forwarding yes$:X11Forwarding no:g\' /etc/ssh/sshd_config'
          'sudo sed -i \'s:^#\\?MaxAuthTries [0-9]\\+$:MaxAuthTries 6:g\' /etc/ssh/sshd_config'
          'sudo sed -i \'s:^#\\?PasswordAuthentication yes$:PasswordAuthentication no:g\' /etc/ssh/sshd_config'
          'sudo sed -i \'s:^#\\?PermitRootLogin .\\+$:PermitRootLogin no:g\' /etc/ssh/sshd_config'
          'echo "Completed "sshd settings changes"'
        ]
      }
      {
        type: 'Shell'
        name: 'Install Azure CLI'
        inline: [
          'echo "Starting "Azure CLI install"'
          'curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash'
          'echo "Completed "Azure CLI install"'
        ]
      }
      {
        type: 'Shell'
        name: 'Install Azure CLI extensions'
        inline: [
          'echo "Starting "AZ CLI extension add"'
          'sudo az extension add -n aks-preview'
          'echo "Completed "AZ CLI extension add"'
        ]
      }
      {
        type: 'Shell'
        name: 'Install kubectl and kubelogin'
        inline: [
          'echo "Starting "kubectl install"'
          'sudo az aks install-cli'
          'echo "Completed "kubectl install"'
        ]
      }
      {
        type: 'Shell'
        name: 'Install helm'
        inline: [
          'echo "Starting "helm install"'
          'curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash'
          'echo "Completed "helm install"'
        ]
      }
      {
        type: 'Shell'
        name: 'Install flux'
        inline: [
          'echo "Starting "flux install"'
          'curl -s https://fluxcd.io/install.sh | sudo bash'
          'echo "Completed "flux install"'
        ]
      }
      {
        type: 'Shell'
        name: 'Install workload identity tooling'
        inline: [
          'echo "Starting "k8s workload identity CLI install"'
          'wget -c https://github.com/Azure/azure-workload-identity/releases/download/v0.8.0/azwi-v0.8.0-linux-amd64.tar.gz -O azwi-binary.tar.gz'
          'tar -xvf ./azwi-binary.tar.gz azwi'
          'sudo mv azwi /usr/local/bin/azwi'
          'rm -Rf azwi azwi-binary.tar.gz'
          'echo "Completed "k8s workload identity CLI install"'
        ]
      }
      {
        type: 'Shell'
        name: 'Install Open Service Mesh tooling'
        inline: [
          'echo "Starting "OSM install"'
          'wget -c https://github.com/openservicemesh/osm/releases/download/v1.0.0/osm-v1.0.0-linux-amd64.tar.gz -O osm-binary.tar.gz'
          'tar -xvf ./osm-binary.tar.gz'
          'sudo mv ./linux-amd64/osm /usr/local/bin/osm'
          'rm -Rf ./linux-amd64 osm-binary.tar.gz'
          'echo "Completed "OSM install"'
        ]
      }
      {
        type: 'Shell'
        name: 'Install Terraform'
        inline: [
          'echo "Starting "Terraform install"'
          'sudo apt-get -yq install unzip'
          'curl -LO https://releases.hashicorp.com/terraform/1.1.5/terraform_1.1.5_linux_amd64.zip'
          'sudo unzip -o terraform_1.1.5_linux_amd64.zip -d /usr/local/bin'
          'rm -f terraform_1.1.5_linux_amd64.zip'
          'echo "Completed "Terraform install"'
        ]
      }
    ]
  }
}
