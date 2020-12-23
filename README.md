# Azure Kubernetes Service (AKS) Jumpbox Builder

INTRODUCTION HERE

## Solution

[Azure Image Builder](https://docs.microsoft.com/azure/virtual-machines/image-builder-overview) (AIB) is a managed service that generates Managed VM Images for you based on the [HashiCorp Packer](https://www.packer.io)  specification.

While these instructions are targeting the building of a general-purpose AKS jumpbox VM image, these instructions could be referenced for other VM image purposes. These instructions do NOT address pushing images to a Shared Image Gallery or any other features of the Azure Image Building Service. To see the full features of the service, [review the service's docs](https://docs.microsoft.com/azure/virtual-machines/image-builder-overview).

## Restricted Networking

Azure Image Builder Service supports hosting the image building process in a subnet that you bring. This allows you to generate the images within the security constraints of your own network, providing both inbound and outbound network controls. It also allows you to access network-restricted resources you wish to include in your final image. This implementation is built around the bring-your-own-subnet model and provides no instructions for the more permissive model that results in your image building compute to be unfiltered and directly accessible from the internet.

## Deployment Steps

### Prerequisites

1. **Select or build a suitable subnet.** This subnet needs to meet the following requirements.
    1. The subnet must be no smaller than a `/28`, and must have **four IP addresses available**.
    1. The subnet may have an Network Security Group (NSG) applied to it as long as it is at least as permissive as the following:

        **Inbound**

        | Source            | Source Port | Destination    | Destination Port   | Protocol | Action | Reason                     |
        |-------------------|-------------|----------------|--------------------|----------|--------|----------------------------|
        | AzureLoadBalancer | *           | VirtualNetwork | 60001              | TCP      | Allow  | Needed for AIB connections |
        | TODO | *           | TODO | TODO              | TCP      | Allow  | Needed for AIB connections |
        | Any            | *           | Any         | *                | Any      | Deny  | Block all other inbound traffic |

        **Outbound**

        | Source         | Source Port | Destination | Destination Port | Protocol | Action | Reason   |
        |----------------|-------------|-------------|------------------|----------|--------|----------|
        | VirtualNetwork | *           | Internet    | 443              | TCP      | Allow  | AIB reaches out to Azure Storage to push logs and VHD image |
        | VirtualNetwork | *           | _as needed_ | _as needed_      | _as needed_ | Allow  | Must allow access to any additional resources your image's packer specification uses as part of the build process. |
        | Any            | *           | Any         | *                | Any      | Deny  | Block all other outbound traffic |

        Ensure Azure Diagnostics and/or NSG Flow Logs are configured to help you troubleshoot any unexpected blocked traffic.

        Note, there is UDP traffic that will be blocked with the above configuration. As the transient VMs are booting, they attempt to make NTP connections. Unless your situation requires otherwise, it's safe to block those here, the process will still function.

    1. The subnet may have a **route table** applied to it that force tunnels Next Hop to your NVA (such as an Azure Firewall in a hub network).
    1. The subnet must have `privateLinkServiceNetworkPolicies` set to `Disabled` as PrivateLink is how Azure Image Builder Service communicates with your transient build agent.
    1. The subnet must be in the same subscription as the resource group you deploy the AIB service to and the same subscription as the resource group the Managed Image is created in. This is NOT a limitation of the AIB service, instead a limitation of the ARM templates presented in this repo. Those artifacts can be extended to support cross-subscription building/publishing. The subnet, AIB Service, and the final Managed Image can all be in separate resource groups or all/partly co-located if desired.
    1. The subnet must be located in one of the following regions: East US, East US 2, West Central US, West US, West US 2, North Europe, West Europe.
1. **Your subnet's _egress_ firewall _(if any)_ must be at least as permissive as the following.** This is in addition to the built-in ["Azure infrastructure FQDNs" rule that is found in Azure Firewall](https://docs.microsoft.com/azure/firewall/infrastructure-fqdns).

    |Source      |Protocol:Port |Target FQDNs             |Reason   |
    |------------|--------------|-------------------------|---------|
    |Subnet CIDR | `HTTPS`:`443`    | `*.blob.core.windows.net` | AIB will dynamically create a blob storage account when an image is being built. Its operation logs will be stored there along with other runtime requirements, and the final image will be staged there as well. It's not possible to know the name of this storage account ahead of time to make this rule more specific. |
    |Subnet CIDR | HTTPS:443 | _as needed_        | Any endpoints your image's configuration specification uses as part of the build process. If possible, bring these external dependencies into a resource endpoint that you manage for maximum control.  |

    For the image built by this repo's contents, your NVA does not need to allow any other outbound access. There are a few additional HTTPS connections made while the transient AIB VMs boot (e.g. `api.snapcraft.io`, `entropy.ubunutu.com`, `changelogs.ubunutu.com`). Those are safe to block and will not prevent this process from functioning. If you don't block UDP connections at the subnet's NSG, you'll also be blocking NTP (`UDP`:`123`) traffic with the above rules. Unless you have a specific reason to allow it, this too is safe to block. NTP is invoked as the transient AIB VMs boot.
1. Ensure you have **sufficient Azure permissions**.

    | Role      | Scope      | Reason |
    |-----------|------------|--------|
    |TODO | TODO    | TODO |
1. **Ensure you accept the risk of preview features**. Azure Image Builder Service is currently in public preview and as with any preview the service does not come with support, is subject to breaking changes, and supporting material like this is maintained in low-priority manor. For more information, see [Supplemental Terms of Use for Microsoft Azure Previews](https://azure.microsoft.com/support/legal/preview-supplemental-terms/).
1. **Ensure you're okay with the Azure Marketplace Ubuntu 18.04 LTS as your base image.** Azure Image Builder supports more base OS images than the one selected in this implementation (you can even bring your own), however images other than the one selected here have not been evaluated with regard to the above networking restrictions. If you choose to use another base image, you may need to adjust various elements of these instructions.
1. **Ensure you're okay with an "Infrastructure Resource Group" being created on your behalf.** AIB Service will create, be assigned permissions to, and delete a workspace resource group that is prefixed with `IT_`. This is a requirement for this service and is much like the infrastructure resource group for AKS.

### Deploying Azure Image Builder Service

1. Register the preview feature. To use Azure Image Builder, you need to [register the feature](https://docs.microsoft.com/azure/virtual-machines/linux/image-builder#register-the-features).

   ```azurecli
   az feature register --namespace Microsoft.VirtualMachineImages --name VirtualMachineTemplatePreview
   ```

   Wait for "Registered" state, this may take 10 minutes. You can check this status by running the following command.

   ```azurecli
   az feature show --namespace Microsoft.VirtualMachineImages --name VirtualMachineTemplatePreview
   ```

   Once registered, re-register the Microsoft.VirtualMachineImages provider.

   ```azurecli
   az provider register -n Microsoft.VirtualMachineImages
   ```

1. Ensure your target subnet matches the spec above.
1. Ensure your permissions match the spec above.
1. Deploy Azure RBAC Custom Roles (Optional, but highly recommended)
1. Create Azure Image Builder Resource Group
1. Deploy AIB Service's Managed Identity and assign roles
1. Deploy AIB's AKS Image Template
1. Build your jumpbox image
1. Capture any log data desired to be retained
1. Delete Temporary Role Assignments (Optional, but highly recommended)
1. Delete Temporary Azure Resources (Optional)

### Try Your Image

TODO

### Costs

There is no cost for Azure Image Builder service directly, instead of the costs of the transient resources deployed to the infrastructure resource group and related network costs comprise the bulk of the cost. See the [Costs](https://docs.microsoft.com/azure/virtual-machines/image-builder-overview#costs) section of the service's docs.
