# Azure Local Configuration Report

**Cluster:** `fmazlocal`  
**Resource Group:** `rg-azurelocal-prod-westeurope`  
**Subscription:** Fellowmind-FMDK-CIS-AzureLocal (`581f8b45-6fef-4e04-a221-d3eabd0525b4`)  
**Location:** westeurope  
**Generated:** 2026-08-28 17:34 UTC  
**Data Sources:** Azure ARM + PowerShell remoting (`AZL-1`)  

---

## Table of Contents

- [Report Metadata](#report-metadata)
- [Validation Summary](#validation-summary)
- [Configuration Summary](#configuration-summary)
  - [Deployment Scenario & Scale](#deployment-scenario--scale)
  - [Node Configuration](#node-configuration)
  - [Network Configuration](#network-configuration)
  - [Active Directory Configuration](#active-directory-configuration)
  - [Security Configuration](#security-configuration)
  - [Microsoft Defender for Cloud](#microsoft-defender-for-cloud)
  - [Billing & Licensing](#billing--licensing)
  - [Monitoring & Insights](#monitoring--insights)
- [Workloads & Platform Configuration](#workloads--platform-configuration)
  - [Azure Arc & Extensions](#azure-arc--extensions)
  - [Virtual Machines & Images](#virtual-machines--images)
  - [Kubernetes Clusters](#kubernetes-clusters)
  - [Updates](#updates)
  - [Storage Configuration](#storage-configuration)

---

## Report Metadata

| Property | Value |
| --- | --- |
| Cluster Name | `fmazlocal` |
| Location | westeurope |
| Connectivity Status | ✓ Connected |
| Cluster Status | ✓ ConnectedRecently |
| Provisioning State | ✓ Succeeded |
| Cluster Version | 10.0.26100 |
| OS Display Version | 24H2 |
| Manufacturer | Lenovo |
| Cluster Type | ThirdParty |
| Billing Model | Standard |
| Trial Days Remaining | N/A |
| Last Billing | 8/28/2026 5:13:10 PM |
| Registration Date | 11/12/2025 2:13:07 PM |
| Last Sync | 8/28/2026 11:00:03 AM |
| IMDS Attestation | ✓ Enabled |
| Diagnostic Level | Basic |
| Azure Portal URL | https://portal.azure.com/#resource/subscriptions/581f8b45-6fef-4e04-a221-d3eabd0525b4/resourceGroups/rg-azurelocal-prod-westeurope/providers/microsoft.azurestackhci/clusters/fmazlocal/overview |
| Service Endpoint | `https://dp.stackhci.azure.com/westeurope/` |
| Cluster ID (CloudId) | 1811501b-855a-4cb1-87db-1292ca3dab62 |
| AAD Tenant ID | `7de6b2d4-2134-407d-abb8-4a1a36a300e4` |
| Custom Location | `fmazlocal` |
| Arc Resource Bridge | `fmazlocal-arcbridge` |
| Tags | None |

---

## Validation Summary

> This section reflects the **observed state** of the cluster at report generation time.

| Status | Check | Detail |
| --- | --- | --- |
| ✓ Connected | Cluster Connectivity | Connected |
| ✓ Succeeded | Cluster Provisioning State | Succeeded |
| ✓ Connected | Arc Aggregate State | Connected |
| ✓ All healthy | Arc Extensions | 4 extension(s) provisioned successfully |
| ✓ Up to date | Updates | 4 update record(s), none pending |
| ✓ 2 found | Logical Networks | lan-standard, fmazlocal-InfraLNET |
| ⚠ Not enabled | Defender for Cloud | All plans on Free tier — no paid Defender coverage |
| ⚠ Not configured | Azure Monitor Insights | No AzureMonitorWindowsAgent or Data Collection Rules found — logs not forwarded |

---

## Configuration Summary

### Deployment Scenario & Scale

**Deployment Mode:** `Deploy`  
**Node Count:** 2  
**Storage Configuration Mode:** `Express`  
**Witness Type:** `Cloud`  
**Naming Prefix:** `HCI01`  

**Cluster Version:** `10.0.26100`  
**Cluster Type:** `ThirdParty`  
**Manufacturer:** `Lenovo`  
**IMDS Attestation:** ✓ Enabled  
**Diagnostic Level:** `Basic`  
**OEM Activation:** `Disabled`  

**Supported Capabilities:** `ManagedIdentity`, `CloudManagement`, `CloudManagedUpdates`, `CloudManagedUpdatesV2`, `MicrosoftAttestationServiceAvailability`, `AddServer`, `RepairServer`, `AddNetworkIntent`  

**Attestation Service:** `https://fmazlo1811501b855a4cb1.weu.attest.azure.net`  

### Node Configuration

| Node | IP Address | Model | OS Version | Serial | Cores | Memory | OEM Act. |
| --- | --- | --- | --- | --- | --- | --- | --- |
| AZL-2 | `10.20.0.12` | ThinkEdge SE350 V2 | 24H2 | `J701WTN4` | 8 | 128 GiB | Disabled |
| AZL-1 | `10.20.0.11` | ThinkEdge SE350 V2 | 24H2 | `J701WTN5` | 8 | 128 GiB | Disabled |

**Cluster Node States** *(via PowerShell remoting from `AZL-1`)*

| Node | State | ID |
| --- | --- | --- |
| AZL-1 | ✓ Up | 2 |
| AZL-2 | ✓ Up | 1 |

**GPU Hardware** *(via PowerShell remoting from `AZL-1`)*

| GPU | Driver Version | VRAM | Status |
| --- | --- | --- | --- |
| ASPEED Graphics Family(WDDM) | 9.0.10.115 | 0 GB | ✓ OK |

**Local Administrators Group** *(via PowerShell remoting from `AZL-1`)*

| Account | Type | Source |
| --- | --- | --- |
| AZL\AzureLocalDeployment | User | ActiveDirectory |
| AZL\CAUfmazlhuy$ | User | ActiveDirectory |
| AZL\Domain Admins | Group | ActiveDirectory |
| AZL-1\ASBuiltInAdmin | User | Local |
| AZL-1\ECEAgentService | User | Local |
| AZL-1\HCIOrchestrator | User | Local |
| NT SERVICE\Azure Stack HCI Download Service | Group | Unknown |
| NT SERVICE\Azure Stack HCI Health Service | Group | Unknown |
| NT SERVICE\Azure Stack HCI Update Service | Group | Unknown |
| NT SERVICE\AzureEMP | Group | Unknown |
| NT SERVICE\AzureStack Agent Lifecycle Agent | Group | Unknown |
| NT SERVICE\AzureStack File Copy Agent | Group | Unknown |
| NT SERVICE\AzureStack HyperSync Agent | Group | Unknown |
| NT SERVICE\AzureStack Security AzureMonitor Agent | Group | Unknown |
| NT SERVICE\HealthAgent | Group | Unknown |


### Network Configuration

#### Infrastructure Network

| Setting | Value |
| --- | --- |
| Gateway | `10.20.0.1` |
| Subnet Mask | `255.255.255.0` |
| DNS Servers | `10.128.0.4` |
| Use DHCP | N/A |

**IP Pool:**

| Start IP | End IP |
| --- | --- |
| `10.20.0.20` | `10.20.0.29` |

#### Host Networking Intents

**Storage Auto IP:** `True`  
**Storage Switchless:** `True`  

**Intent: `Compute_Management`**

| Property | Value |
| --- | --- |
| Traffic Type | Management, Compute |
| Adapters | Port4 |
| Jumbo Packet | 1514 |
| RDMA Enabled | Enabled |
| RDMA Technology | RoCEv2 |

**Intent: `Storage`**

| Property | Value |
| --- | --- |
| Traffic Type | Storage |
| Adapters | Port6, Port5 |
| Jumbo Packet | 1514 |
| RDMA Enabled | Enabled |
| RDMA Technology | RoCEv2 |

**Storage Networks:**

| Name | Adapter | VLAN |
| --- | --- | --- |
| `StorageNetwork1` | `Port6` | `711` |
| `StorageNetwork2` | `Port5` | `712` |

#### Node NICs

> *Via PowerShell remoting from `AZL-1`.*

| Adapter | Description | Speed | MAC Address |
| --- | --- | --- | --- |
| Port0 | IBM USB Remote NDIS Network Device | 426.0 Mbps | `8E-3B-4A-80-C0-67` |
| Port6 | Intel(R) Ethernet Connection E823-C for SFP #4 | 10 Gbps | `8C-3B-4A-80-C0-63` |
| Port4 | Intel(R) Ethernet Connection E823-C for SFP | 10 Gbps | `8C-3B-4A-80-C0-61` |
| vManagement(compute_management) | Hyper-V Virtual Ethernet Adapter | 10 Gbps | `8C-3B-4A-80-C0-61` |
| Port5 | Intel(R) Ethernet Connection E823-C for SFP #3 | 10 Gbps | `8C-3B-4A-80-C0-62` |

#### Logical Networks

**`lan-standard`**

**VM Switch:** `ConvergedSwitch(compute_management)`  
**Provisioning State:** ✓ Succeeded  

| Subnet | CIDR | Allocation | VLAN |
| --- | --- | --- | --- |
| lan-standard | `10.30.0.0/24` | Static | 30 |

**`fmazlocal-InfraLNET`**

**VM Switch:** `ConvergedSwitch(compute_management)`  
**Provisioning State:** ✓ Succeeded  

| Subnet | CIDR | Allocation | VLAN |
| --- | --- | --- | --- |
| vnet-arcbridge-subnet | `10.20.0.0/24` | Static | N/A |

#### Network Security Groups

**`NSG1`** — ✓ Succeeded

| Property | Value |
| --- | --- |
| Provisioning State | ✓ Succeeded |
| Logical Networks | lan-standard |
| Network Interfaces | testvm-nic |
| Security Rules | 2 |

**Inbound Rules**

| Rule | Priority | Access | Protocol | Source | Dst Port |
| --- | --- | --- | --- | --- | --- |
| AllowAll | 100 | Allow | Any | * | * |

**Outbound Rules**

| Rule | Priority | Access | Protocol | Source | Dst Port |
| --- | --- | --- | --- | --- | --- |
| AllowAllOutbound | 100 | Allow | Any | * | * |

### Active Directory Configuration

**Domain FQDN:** `azl.local`  
**OU Path:** `OU=azlocal,DC=azl,DC=local`  
**Secrets Location:** `https://kv-fmazlocal-hci-2.vault.azure.net/`  

### Security Configuration

| Security Setting | Value |
| --- | --- |
| BitLocker Boot Volume | True |
| BitLocker Data Volume | True |
| Credential Guard | True |
| Drift Control | True |
| DRTM Protection | True |
| HVCI Protection | True |
| Side Channel Mitigation | True |
| SMB Cluster Encryption | N/A |
| SMB Signing | True |
| WDAC | True |

### Microsoft Defender for Cloud

| Plan | Status |
| --- | --- |
| Defender for Servers (VMs) | — Free / Not enabled |
| Defender for Storage | — Free / Not enabled |
| Defender for SQL on Machines | — Free / Not enabled |
| Defender for Kubernetes | — Free / Not enabled |
| Defender for DNS | — Free / Not enabled |
| Defender for Containers | — Free / Not enabled |

### Billing & Licensing

| Property | Value |
| --- | --- |
| Billing Model | Standard |
| Trial Days Remaining | N/A |
| Last Billing Timestamp | 8/28/2026 5:13:10 PM |
| Software Assurance Status | ⚠ Disabled |
| Software Assurance Intent | Disable |
| Windows Server Subscription | ⚠ Disabled |

### Monitoring & Insights

> **⚠ Advisory:** Azure Monitor agent not detected and no Data Collection Rules found in this resource group. Cluster Insights (log forwarding to Log Analytics) appears to be **not configured**.

---

## Workloads & Platform Configuration

### Azure Arc & Extensions

| Property | Value |
| --- | --- |
| Arc Instance Resource Group | rg-azurelocal-prod-westeurope |
| Aggregate State | ✓ Connected |
| Arc Application Object ID | `N/A` |
| Arc SP Object ID | `N/A` |

| Extension | Type | Version | State | Managed By |
| --- | --- | --- | --- | --- |
| AzureEdgeTelemetryAndDiagnostics | `TelemetryAndDiagnostics` | 2.0.48.0 | ✓ Succeeded | Azure |
| AzureEdgeLifecycleManager | `LcmController` | 30.2607.0.1310 | ✓ Succeeded | Azure |
| AzureEdgeRemoteSupport | `EdgeRemoteSupport` | 1.0.13.2 | ✓ Succeeded | Azure |
| AzureEdgeDeviceManagement | `DeviceManagementExtension` | 1.2610.2.3101 | ✓ Succeeded | Azure |

### Virtual Machines & Images

| VM Name | Resource Group | Subscription | Location | State |
| --- | --- | --- | --- | --- |
| testvm | rg-azlocal-vms | (current) | westeurope | ✓ Succeeded |
| avd01xyz-0 | rg-vdpool01 | (current) | westeurope | ✓ Succeeded |

**Available Images:**

| Name | Source | OS | Hyper-V Gen | State |
| --- | --- | --- | --- | --- |
| win11-24h2-ent-01 | marketplacegalleryimages | Windows | V2 | ✓ Succeeded |
| win11-24h2-avd-01 | marketplacegalleryimages | Windows | V2 | ✓ Succeeded |
| 2022-datacenter-azure-edition-01 | marketplacegalleryimages | Windows | V2 | ✓ Succeeded |

### Kubernetes Clusters

_No Kubernetes clusters found in this resource group._

### Updates

| Name | Version | State | Availability | Release Notes |
| --- | --- | --- | --- | --- |
| 2026.08 Cumulative Update | `12.2608.1003.8` | Installed | Local | https://go.microsoft.com/fwlink/?linkid=2375205 |
| 2026.07 Cumulative Update | `12.2607.1003.73` | Installed | Local | https://go.microsoft.com/fwlink/?linkid=2371618 |
| 2026.04 Feature Update | `12.2604.1003.1006` | Installed | Local | https://go.microsoft.com/fwlink/?linkid=2359185 |
| 2026.03 Cumulative Update | `12.2603.1002.502` | Installed | Online | https://go.microsoft.com/fwlink/?linkid=2358909 |

### Storage Configuration

> *Via PowerShell remoting from `AZL-1`.*

| Pool Name | Status | Total | Allocated |
| --- | --- | --- | --- |
| SU1_Pool | ✓ OK | 7146 GB | 1678 GB |

**Volumes:**

| Volume | File System | Size | Free | Health |
| --- | --- | --- | --- | --- |
| Recovery | NTFS | 0.7 GB | 0.2 GB | ✓ Healthy |
| Windows | NTFS | 893.1 GB | 806.4 GB | ✓ Healthy |
| SYSTEM | FAT32 | 0.3 GB | 0.3 GB | ✓ Healthy |
| UserStorage_2 | CSVFS | 2215.9 GB | 2053.7 GB | ✓ Healthy |
| UserStorage_1 | CSVFS | 2215.9 GB | 1836.7 GB | ✓ Healthy |
| Infrastructure_1 | CSVFS | 251.9 GB | 163.8 GB | ✓ Healthy |
| ClusterPerformanceHistory | ReFS | 20 GB | 18.5 GB | ✓ Healthy |

**Physical Disks** *(sampled from first node):*

| Model | Media | Bus | Size | Status |
| --- | --- | --- | --- | --- |
| Intel Raid Volume | SSD | RAID | 894.2 GB | ✓ OK |
| Micron_7450_MTFDKCB960TFR | SSD | NVMe | 894.3 GB | ✓ OK |
| Micron_7450_MTFDKCB960TFR | SSD | NVMe | 894.3 GB | ✓ OK |
| Micron_7450_MTFDKCB960TFR | SSD | NVMe | 894.3 GB | ✓ OK |
| Micron_7450_MTFDKCB960TFR | SSD | NVMe | 894.3 GB | ✓ OK |
| Micron_7450_MTFDKCB960TFR | SSD | NVMe | 894.3 GB | ✓ OK |
| Micron_7450_MTFDKCB960TFR | SSD | NVMe | 894.3 GB | ✓ OK |
| Micron_7450_MTFDKCB960TFR | SSD | NVMe | 894.3 GB | ✓ OK |
| Micron_7450_MTFDKCB960TFR | SSD | NVMe | 894.3 GB | ✓ OK |

---

*Generated by Get-AzLocalDoc for Azure Local ([Get-AzLocalDoc](https://github.com/chkja/Get-AzLocalDoc)) — 2026-08-28T17:34:15Z*


