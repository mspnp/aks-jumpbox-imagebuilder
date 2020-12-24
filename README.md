# Azure Kubernetes Service (AKS) Jumpbox Builder

Many customers wish to restrict network access to their AKS cluster's control plane (API Server) to reduce abuse and malicious behavior. This is done via API Server Allowlist IP filters or the AKS Private Server offering. Unless often means a cluster operator can no longer directly `kubectl` or perform similar administrative actions against the cluster directly from their own workstation. A common solution is to use a jumpbox, residing on a subnet that has been granted sufficient access to the API Server and/or nodepool nodes.

These jumpboxes are used at various points in the lifecycle of a cluster, most notably in break-fix situations. When a high severity issue is happening, you want immediate access to resolve the issue efficiently. This means that the jumpbox should include all of your expected operations tooling, be highly available, and because it's got network line-of-sight to your cluster's control plane, it needs to be a governed/observable resource.

## Solution

[Azure Image Builder](https://docs.microsoft.com/azure/virtual-machines/image-builder-overview) (AIB) is a managed service that generates managed VM Images for you based on the [HashiCorp Packer](https://www.packer.io) specification. We'll use this service to build a general-purpose AKS jumpbox image that you could consider using as a starting point for your own jumpbox image. We include common administrative tooling. While this image could be built in many other ways, we feel the Azure Image Builder can help customers think about their jumpbox image in a way that can be successfully managed via Infrastructure as Code and integrated into build pipelines.

This image has not undergone any specific hardening or integration with security agents (anti-virus, FIM, etc). Before you take a dependency on this, or any jumpbox image, ensure it complies with your requirements.

While these instructions are targeting the building of a general-purpose AKS jumpbox VM image, these instructions could be referenced for other VM image purposes (such as build agents). These instructions do NOT address pushing images to a Shared Image Gallery, using Gen-2 VMs, or any other features of the Azure Image Building Service. To see the full features of the service, [review the service's docs](https://docs.microsoft.com/azure/virtual-machines/image-builder-overview).

## Isolated Build Network

Azure Image Builder Service supports hosting the image building process in a subnet that you bring. This feature allows you to generate the images within the security constraints of your own network; providing inbound & outbound network controls. It also allows you to access network-restricted resources you wish to include in your final image. This specific AKS jumpbox implementation is built around this bring-your-own-subnet model and provides no instructions for the more network-lax model.

## Deployment Steps

### Prerequisites

1. **Select or build a suitable subnet.** This subnet needs to meet the following requirements.
    1. The subnet must be no smaller than a `/28`, and must have **four IP addresses available**.

       The IPs will be allocated for the following purposes:
       * One Internal Azure Load Balancer (Standard)
       * One NIC attached to the AIB Proxy VM, which orchestrates the building of the image.
       * One NIC for the PrivateLink service that allows connectivity between the AIB Service and the AIB Proxy VM.
       * One NIC for the Packer VM used to build the final image.

    1. The subnet may have an Network Security Group (NSG) applied to it as long as it is at least as permissive as the following:

        **Inbound**

        | Source            | Source Port | Destination    | Destination Port   | Protocol | Action | Reason                     |
        |-------------------|-------------|----------------|--------------------|----------|--------|----------------------------|
        | AzureLoadBalancer | *           | VirtualNetwork | `60001`              | TCP      | Allow  | LoadBalancer Health Probe to AIB Proxy VM (`60001` is SSH on Proxy VM) |
        | VirtualNetwork    | *           | VirtualNetwork | `60001`              | TCP      | Allow  | From AIB PrivateLink IP to AIB Proxy VM |
        | VirtualNetwork    | *           | VirtualNetwork | `22`              | TCP      | Allow  | Needed for Packer VM to receive SSH connection from AIB Proxy VM |
        | Any               | *           | Any         | *                | Any      | Deny  | Block all other inbound traffic |

        **Outbound**

        | Source         | Source Port | Destination    | Destination Port | Protocol | Action | Reason   |
        |----------------|-------------|----------------|------------------|----------|--------|----------|
        | VirtualNetwork | *           | Internet       | `443`              | TCP      | Allow  | AIB Proxy reaches out to Azure Management API & Azure Storage to push logs and VHD image. AIB Packer VM reaches out to Azure Storage. This traffic can be restricted further in your egress firewall solution. |
        | VirtualNetwork | *           | VirtualNetwork | `22`               | TCP      | Allow  | Needed for AIB proxy VM to connect to Packer VM via SSH to initiate image build. |
        | VirtualNetwork | *           | _as needed_ | _as needed_      | _as needed_ | Allow  | Must allow access to any additional resources your image's packer specification uses as part of the build process. |
        | Any            | *           | Any         | *                | Any      | Deny  | Block all other outbound traffic |

        Ensure Azure Diagnostics and/or NSG Flow Logs are configured to help you troubleshoot any unexpected blocked traffic.

        Note, there is UDP traffic that will be blocked with the above configuration. As the two VMs are booting, they attempt to make NTP connections. Unless your situation requires otherwise, it's safe to block those here, the process will still function.

        For the image built by this repo's contents, your NSG does not need to allow any other _as needed_ outbound access.

    1. The subnet may have a **route table** applied to it that force tunnels Next Hop to your NVA (such as an Azure Firewall in a hub network).
    1. The subnet must have `privateLinkServiceNetworkPolicies` set to `Disabled` as PrivateLink is how Azure Image Builder Service and the transient AIB Proxy VM communicates.
    1. The subnet must be in the same subscription as the resource group you deploy the AIB service to and the same subscription as the resource group the Managed Image is created in. This is NOT a limitation of the AIB service, instead a limitation of the ARM templates presented in this repo. Those artifacts can be extended to support cross-subscription building/publishing. The subnet, AIB Service, and the final Managed Image can all be in separate resource groups or all/partly co-located if desired.
    1. The subnet must be located in one of the following regions: East US, East US 2, West Central US, West US, West US 2, North Europe, West Europe.
1. **Your subnet's _egress_ firewall _(if any)_ must be at least as permissive as the following.** This is in addition to the built-in ["Azure infrastructure FQDNs" rule that is found in Azure Firewall](https://docs.microsoft.com/azure/firewall/infrastructure-fqdns).

    |Source      |Protocol:Port |Target FQDNs                 |Reason   |
    |------------|--------------|-----------------------------|---------|
    |Subnet CIDR | HTTPS:`443`  | `*.blob.core.windows.net` | AIB will dynamically create a blob storage account when an image is being built. Its operation logs will be stored there along with other runtime requirements, and the final image will be staged there as well. It's not possible to know the name of this storage account ahead of time to make this rule more specific. |
    |Subnet CIDR | HTTPS:`443` | _as needed_        | Any endpoints your image's configuration specification uses as part of the build process. If possible, bring these external dependencies into a resource endpoint that you manage for maximum control.  |

    For the image built by this repo's contents, your NVA does not need to allow any other _as needed_ outbound access. There are a few additional HTTPS connections made while the transient AIB VMs boot (e.g. `api.snapcraft.io`, `entropy.ubunutu.com`, `changelogs.ubunutu.com`). Those are safe to block and will not prevent this process from functioning. If you don't block UDP connections at the subnet's NSG, you'll also be blocking NTP (`UDP`:`123`) traffic with the above rules. Unless you have a specific reason to allow it, this too is safe to block. NTP is invoked as the transient AIB VMs boot.
1. Ensure you have **sufficient Azure permissions**.

    | Role      | Scope      | Reason |
    |-----------|------------|--------|
    |TODO       | TODO       | TODO   |
1. **Ensure you accept the risk of preview features**. Azure Image Builder Service is currently in _public preview_ and as with any preview the service does not come with support, is subject to breaking changes, and supporting material like this is maintained in low-priority manor. For more information, see [Supplemental Terms of Use for Microsoft Azure Previews](https://azure.microsoft.com/support/legal/preview-supplemental-terms/).
1. **Ensure you're okay with the Azure Marketplace Ubuntu 18.04 LTS as your base image.** Azure Image Builder supports more base OS images than the one selected in this implementation, however images other than the one selected here have not been evaluated with regard to the above networking restrictions. If you choose to use a different base image, you may need to adjust various elements of these instructions.
1. **Ensure you're okay with an "Infrastructure Resource Group" being created on your behalf.** AIB Service will create, be assigned permissions to, and delete a workspace resource group that is prefixed with `IT_`. This is a requirement for this service and is much like the infrastructure resource group for AKS. It will be in existence as long as you keep the image template deployed.

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
1. Clone Repo
1. Deploy Azure RBAC Custom Roles (Optional, but highly recommended)
1. Create Azure Image Builder Resource Group
1. Deploy AIB Service's Managed Identity and assign roles
1. Deploy AIB's AKS Image Template
1. Build your jumpbox image
1. Capture any log data desired to be retained
1. Delete Temporary Role Assignments (Optional, but highly recommended)
1. Delete Temporary Azure Resources (Optional)

### Try Your Image

Now that you have an image, you can create a VM or a VMSS based off of that image. Simply place that compute in a secured subnet with network line-of-sight to your AKS Cluster API Server and then use Azure Bastion to connect.

### Costs

There is no cost for Azure Image Builder service directly, instead of the costs of the transient resources deployed to the infrastructure resource group and related network costs comprise the bulk of the cost. See the [Costs](https://docs.microsoft.com/azure/virtual-machines/image-builder-overview#costs) section of the service's docs.
