targetScope = 'resourceGroup'

@description('sadf')
param location string

param imageTemplateName string = 'imgt-askopsjb-${utcNow('yyyyMMddTHHmmss')}'

param existingSubnetResourceId string

param imageDestinationResourceGroup string

param imageName string

resource buildVirutalNetworkResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' existing = {
  scope: subscription()
  name: split(existingSubnetResourceId, '/')[3]
}

resource buildVirtualNetwork 'Microsoft.Network/virtualNetworks@2021-05-01' existing = {
  scope: buildVirutalNetworkResourceGroup
  name: split(existingSubnetResourceId, '/')[5]

  resource buildSubnet 'subnets@2021-05-01' existing = {
    name: last(split(existingSubnetResourceId, '/'))
  }
} 

@description('Azure Image Builder (AIB) executes as this identity.')
resource aibUserManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: 'mi-aks-jumpbox-imagebuilder-${uniqueString(resourceGroup().id)}'
  location: location
}

resource bbb 'Microsoft.VirtualMachineImages/imageTemplates@2021-10-01' = {
  name: imageTemplateName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aibUserManagedIdentity}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: 60
    vmProfile: {
      osDiskSizeGB: 32
      vmSize: 'Standard_DS1_v2'
      vnetConfig: {
        subnetId: buildVirtualNetwork::buildSubnet.id
        proxyVmSize: null
      }
    }
    source: {
      type: 'PlatformImage'
      publisher: 'Cononical'
      offer: 'UbuntuServer'
      sku: '18.04-LTS'
      version: 'latest'
    }
    distribute: [
      {
        type: 'ManagedImage'
        runOutputName: 'managedImageTarget'
        location: location
        imageId: resourceId(imageDestinationResourceGroup, 'Microsoft.Compute/images', imageName)
      }
    ]
    customize: [
      {
        type: 'Shell'
        name: 'Update Installed Packages'
        inline: [
          'echo "Starting apt-get update/upgrade"'
          'sudo apt-get -yq update'
          '#sudo apt-get -yq upgrade'
          'echo "Completed apt-get update/ugrade"'
        ]
      }
      {
        type: 'Shell'
        name: 'Adjust sshd settings.'
        inline: [
            'echo "Starting sshd settings changes"'
            'sudo sed -i \'s:^#\\?X11Forwarding yes$:X11Forwarding no:g\' /etc/ssh/sshd_config'
            'sudo sed -i \'s:^#\\?MaxAuthTries [0-9]\\+$:MaxAuthTries 6:g\' /etc/ssh/sshd_config'
            'sudo sed -i \'s:^#\\?PasswordAuthentication yes$:PasswordAuthentication no:g\' /etc/ssh/sshd_config'
            'sudo sed -i \'s:^#\\?PermitRootLogin .\\+$:PermitRootLogin no:g\' /etc/ssh/sshd_config'
            'echo "Completed sshd settings changes"'
        ]
      }
      {
          type: 'Shell'
          name: 'Install Azure CLI'
          inline: [
              'echo "Starting Azure CLI install"'
              'curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash'
              'echo "Completed Azure CLI install"'
          ]
      }
      {
          type: 'Shell'
          name: 'Install Azure CLI extensions'
          inline: [
              'echo "Starting AZ CLI extension add"'
              'sudo az extension add -n aks-preview'
              'echo "Completed AZ CLI extension add"'
          ]
      }
      {
          type: 'Shell'
          name: 'Install kubectl and kubelogin'
          inline: [
              'echo "Starting kubectl install"'
              'sudo az aks install-cli'
              'echo "Completed kubectl install"'
          ]
      }
      {
          type: 'Shell'
          name: 'Install helm'
          inline: [
              'echo "Starting helm install"'
              'curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | sudo bash'
              'echo "Completed helm install"'
          ]
      }
      {
          type: 'Shell'
          name: 'Install flux'
          inline: [
              'echo "Starting flux install"'
              'curl -s https://fluxcd.io/install.sh | sudo bash'
              'echo "Completed flux install"'
          ]
      }
      {
          type: 'Shell'
          name: 'Install Open Service Mesh tooling'
          inline: [
              'echo "Starting OSM install"'
              'wget -c https://github.com/openservicemesh/osm/releases/download/v0.8.4/osm-v0.8.4-linux-amd64.tar.gz -O osm-binary.tar.gz'
              'tar -xvf ./osm-binary.tar.gz'
              'sudo mv ./linux-amd64/osm /usr/local/bin/osm'
              'rm -Rf ./linux-amd64 osm-binary.tar.gz'
              'echo "Completed OSM install"'
          ]
      }
      {
        type: 'Shell'
        name: 'Install Terraform'
        inline: [
            'echo "Starting Terraform install"'
            'sudo apt-get -yq install unzip'
            'curl -LO https://releases.hashicorp.com/terraform/1.0.0/terraform_1.0.0_linux_amd64.zip'
            'sudo unzip -o terraform_1.0.0_linux_amd64.zip -d /usr/local/bin'
            'rm -f terraform_1.0.0_linux_amd64.zip'
            'echo "Completed Terraform install"'
        ]
      }
    ]
  }
}
