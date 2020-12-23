# Azure Kubernetes Service (AKS) Jumpbox Builder

INTRODUCTION HERE

## Solution

Azure Image Builder is a managed service that generates Managed Images for you based on the packer specification.

While these instructions are targeted for building an AKS jumpbox Managed Image, these instructions could be used for other reference purposes. These instructions do NOT address pushing images to a Shared Image Gallery (SIG) or any other features of the Azure Image Building (AIB) Service. To see the full features of the service, review the service's docs.

## Restricted Networking

Azure Image Builder Service supports a bring-your-own-network around the image building process. This allows you to generate the images within the security constraints of your own network, providing both inbound and outbound network controls.  This implementation is built around the bring-your-own-network model. If you don't wish to follow that model, you'll need to modify the contents here to remove all references to the vnet/subnet. If you do this, the image will be built on compute that has direct/unfiltered internet access.

## Steps

### Pre-reqs

1. **Select or build a suitable subnet.** This subnet needs to meet the following requirements.
    1. The subnet must be no smaller than a `/28`, and must have **four** IP addresses available.
    1. The subnet may have an NSG applied to it as long as it meets the following:

        **Inbound** (_Must be at least as permissive as the following._)

        | Source            | Source Port | Destination    | Destination Port   | Protocol | Action | Reason                     |
        |-------------------|-------------|----------------|--------------------|----------|--------|----------------------------|
        | AzureLoadBalancer | *           | VirtualNetwork | 60001              | TCP      | Allow  | Needed for AIB connections |
        | TODO | *           | TODO | TODO              | TCP      | Allow  | Needed for AIB connections |
        | Any            | *           | Any         | *                | Any      | Deny  | Block all other inbound traffic |

        **Outbound** (_Must be at least as permissive as the following._)

        | Source         | Source Port | Destination | Destination Port | Protocol | Action | Reason   |
        |----------------|-------------|-------------|------------------|----------|--------|----------|
        | VirtualNetwork | *           | Internet    | 443              | TCP      | Allow  | AIB reaches out to Azure Storage to push logs and VHD image |
        | VirtualNetwork | *           | _as needed_ | _as needed_      | _as neeeded_ | Allow  | Must allow access to any additional resources your image's packer specification uses as part of the build process. |
        | Any            | *           | Any         | *                | Any      | Deny  | Block all other outbound traffic |

        Ensure Azure Diagnostics and/or NSG Flow Logs are configured to help you troubleshoot any unexpected blocked traffic.

        Note, there is UDP traffic that will be blocked with the above configuration. As the transient VMs are booting, they attempt to make NTP connections. It's safe to block those here, the process will still function.

    1. The subnet may have a route table applied to it that force tunnels Next Hop to your NVA (such as an Azure Firewall in a hub network).
    1. The subnet must `privateLinkServiceNetworkPolicies` set to `Disabled` as PrivateLink is how Azure Image Builder Service communicates with your transient build agent.
    1. The subnet must be in the same subscription as the resource group you deploy the AIB service to and the same subscription as the resource group the Managed Image is created in. (This is NOT a limitation of the AIB service, instead a limitation of the ARM templates used in this repo. They can be extended to support cross-subscription building/publishing.) The subnet, AIB Service, and the final Managed Image can all be in separate resource groups or all/partly co-located if desired.
    1. The subnet must be located in the following regions: TODO-REGION-LIST.
1. **Your subnet's _egress_ firewall _(if any)_ must be at least as permissive as the following.** This is in addition to the built-in "Azure internal traffic" rule that is found in Azure Firewall.

    |Source      |Protocol/Port |Target FQDNs             |Reason   |
    |------------|--------------|-------------------------|---------|
    |Subnet CIDR | HTTPS:443    | *.blob.core.windows.net | AIB will dynamically create a blob storage account and its operation logs will be stored there. Also the final image will be staged in that storage account. It's not possible to know the name of this storage account ahead of time to make this rule more specific. |
    |Subnet CIDR | HTTPS:443 | _as needed_        | Any endpoints your image's packer specification uses as part of the build process. If possible, bring these external dependencies into a resource endpoint that you manage for maximum control.  |

    Your NVA does not need to allow any other outbound access. Note, there are a few additional HTTPS connections made while the transient AIB VMs boot (e.g. `api.snapcraft.io`, `entropy.ubunutu.com`, `changelogs.ubunutu.com`). Those are safe to block and will not prevent this process from functioning. If you don't block UDP connections at the subnet's NSG, you'll also be blocking NTP (UDP 123) traffic with the above rules, unless you have a specific reason to allow it, this too is safe to block. NTP is invoked as the transient AIB VMs boot.
1. Ensure you have **sufficient Azure permissions**.

    | Role      | Scope      | Reason |
    |-----------|------------|--------|
    |TODO | TODO    | TODO |
1. **Ensure you accept the risk of Preview Features**. Azure Image Builder Service is currently in preview and as with any preview, the service does not come with support, is subject to breaking changes, and supporting material like this is supported in low-priority manor.

### Deploying

1. Register the Preview Feature
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
