# Get-AzLocalDoc

A standalone PowerShell script that documents an existing **Azure Local** (formerly Azure Stack HCI) cluster by querying Azure ARM and optionally the HCI nodes directly, then produces a structured **Markdown report**.

> Inspired by [ODIN for Azure Local](https://github.com/Azure/odinforazurelocal) — this is the reverse direction: *existing cluster → documentation*, not *design → deployment*.

---

## What it collects

| Source | Data |
|---|---|
| **Azure ARM** | Cluster identity, region, AAD app IDs, connectivity status |
| **Azure ARM** | Deployment settings: network intents, infrastructure IPs, node list, storage paths, AD/DNS |
| **Azure ARM** | Arc settings and all installed Arc extensions |
| **Azure ARM** | Security settings |
| **Azure ARM** | Logical networks (VLANs, subnets, DHCP, vmSwitchName) |
| **Azure ARM** | Virtual machine instances, gallery images |
| **Azure ARM** | Applied and available updates |
| **HCI Nodes** *(optional)* | Storage pools, volumes, physical disks, network adapters, cluster node state |

---

## Prerequisites

```powershell
Install-Module -Name Az.Accounts  -Scope CurrentUser
Install-Module -Name Az.Resources -Scope CurrentUser
Install-Module -Name Az.StackHCI  -Scope CurrentUser
```

For on-node collection (`-IncludeNodeData`), WinRM/PowerShell remoting must be enabled on the HCI nodes, and the `FailoverClusters` feature must be installed.

---

## Usage

### Interactive login (ARM-only)
```powershell
.\Get-AzLocalDoc.ps1 -ResourceGroupName "rg-azlocal-prod" -ClusterName "hci-cluster-01"
```

### Interactive login with on-node data
```powershell
.\Get-AzLocalDoc.ps1 `
    -ResourceGroupName "rg-azlocal-prod" `
    -ClusterName "hci-cluster-01" `
    -IncludeNodeData `
    -NodeCredential (Get-Credential)
```

### Service principal authentication
```powershell
$cred = New-Object PSCredential(
    "your-app-id",
    (ConvertTo-SecureString "your-secret" -AsPlainText -Force)
)

.\Get-AzLocalDoc.ps1 `
    -ResourceGroupName "rg-azlocal-prod" `
    -TenantId "your-tenant-id" `
    -ServicePrincipal `
    -Credential $cred
```

### Custom output path
```powershell
.\Get-AzLocalDoc.ps1 -ResourceGroupName "rg-azlocal-prod" -OutputPath "C:\docs\cluster.md"
```

---

## Output

A Markdown file with the following sections:

1. Cluster Overview
2. Deployment Configuration (nodes, network intents, infrastructure IPs, storage paths)
3. Network Configuration
4. Storage Configuration *(on-node: pools, volumes, physical disks)*
5. Identity & Security (AAD, AD OU, security settings)
6. Azure Arc & Extensions
7. Logical Networks (VLANs, subnets)
8. Virtual Machines & Images
9. Updates
10. On-Node Data *(optional: cluster nodes, NICs)*

---

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-ResourceGroupName` | ✅ | Resource group containing the cluster |
| `-ClusterName` | | Cluster name (auto-detected if omitted) |
| `-SubscriptionId` | | Override the Az context subscription |
| `-TenantId` | | Required for cross-tenant auth |
| `-ServicePrincipal` | | Use service principal instead of interactive login |
| `-Credential` | With `-ServicePrincipal` | AppId + secret as PSCredential |
| `-IncludeNodeData` | | Collect on-node data via PowerShell remoting |
| `-NodeCredential` | | Credential for HCI node remoting |
| `-OutputPath` | | Output file path (default: `.\<cluster>-doc-<date>.md`) |

---

## Limitations

- **ARM-only mode** does not capture physical NIC details, storage pool internals, or per-node OS-level config — use `-IncludeNodeData` for that.
- `-IncludeNodeData` connects to the **first node only** for cluster-wide S2D data; all nodes report the same storage pool view.
- Secrets, passwords, and sensitive keys are never included (Azure ARM never returns these).
- Some resource types may require specific API versions depending on your cluster's registration age.

---

## License

MIT
