<#
.SYNOPSIS
    Documents an existing Azure Local (Azure Stack HCI) cluster by querying Azure ARM
    and optionally the HCI nodes directly, then generates a Markdown report.

.DESCRIPTION
    Get-AzLocalDoc connects to Azure, discovers all Azure Local resources in a given
    resource group, and produces a structured Markdown documentation file.

    Data sources:
      - Azure ARM   : cluster, Arc settings, extensions, deployment settings,
                      security settings, logical networks, VMs, images, updates
      - HCI nodes   : storage pools, physical NICs, volumes (requires WinRM/PS remoting)

.PARAMETER ResourceGroupName
    The resource group containing the Azure Local cluster.

.PARAMETER ClusterName
    The name of the Azure Local cluster. If omitted, the first cluster found in the
    resource group is used.

.PARAMETER SubscriptionId
    Azure Subscription ID. Defaults to the current Az context subscription.

.PARAMETER TenantId
    Azure Tenant ID. Required when authenticating across tenants.

.PARAMETER ServicePrincipal
    Switch to authenticate using a service principal instead of interactive login.
    Requires -Credential (PSCredential with AppId as username, secret as password).

.PARAMETER Credential
    PSCredential for service principal authentication.

.PARAMETER IncludeNodeData
    Switch to also connect to HCI nodes via PowerShell remoting for on-node data
    (storage pools, physical NICs, volumes). Requires WinRM access to the nodes.

.PARAMETER NodeCredential
    PSCredential for connecting to HCI nodes. If omitted, the current user context
    is used (Kerberos/NTLM).

.PARAMETER OutputPath
    Path for the generated Markdown file.
    Defaults to: .\<ClusterName>-doc-<date>.md

.EXAMPLE
    # Interactive login, ARM-only
    .\Get-AzLocalDoc.ps1 -ResourceGroupName "rg-azlocal-prod" -ClusterName "hci-cluster-01"

.EXAMPLE
    # Interactive login, include on-node data
    .\Get-AzLocalDoc.ps1 -ResourceGroupName "rg-azlocal-prod" -ClusterName "hci-cluster-01" `
        -IncludeNodeData -NodeCredential (Get-Credential)

.EXAMPLE
    # Service principal
    $cred = New-Object PSCredential("app-id-guid", (ConvertTo-SecureString "secret" -AsPlainText -Force))
    .\Get-AzLocalDoc.ps1 -ResourceGroupName "rg-azlocal-prod" -TenantId "tenant-guid" `
        -ServicePrincipal -Credential $cred

.NOTES
    Requires:
      - Az.Accounts, Az.Resources, Az.StackHCI PowerShell modules
      - On-node sections additionally require the FailoverClusters and S2D modules
        installed on the HCI nodes
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $ClusterName,

    [string] $SubscriptionId,

    [string] $TenantId,

    [Parameter(ParameterSetName = 'ServicePrincipal')]
    [switch] $ServicePrincipal,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [PSCredential] $Credential,

    [switch] $IncludeNodeData,

    [PSCredential] $NodeCredential,

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helpers ──────────────────────────────────────────────────────────────

function Write-Step([string]$Message) {
    Write-Host "  → $Message" -ForegroundColor Cyan
}

function Write-Section([string]$Message) {
    Write-Host "`n▶ $Message" -ForegroundColor Yellow
}

function Safe([object]$Value, [string]$Fallback = 'N/A') {
    if ($null -eq $Value -or $Value -eq '') { return $Fallback }
    return $Value.ToString()
}

function Format-Table-Md {
    param([string[]]$Headers, [string[][]]$Rows)
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('| ' + ($Headers -join ' | ') + ' |')
    $null = $sb.AppendLine('| ' + (($Headers | ForEach-Object { '---' }) -join ' | ') + ' |')
    foreach ($row in $Rows) {
        $null = $sb.AppendLine('| ' + ($row -join ' | ') + ' |')
    }
    return $sb.ToString().TrimEnd()
}

function Format-PropTable-Md {
    param([hashtable]$Props)
    $rows = $Props.GetEnumerator() | Sort-Object Key | ForEach-Object {
        @($_.Key, (Safe $_.Value))
    }
    return Format-Table-Md -Headers @('Property', 'Value') -Rows $rows
}

#endregion

#region ── Connect to Azure ─────────────────────────────────────────────────────

Write-Section "Connecting to Azure"

$connectParams = @{}
if ($TenantId)  { $connectParams['TenantId']  = $TenantId }

if ($ServicePrincipal) {
    Write-Step "Authenticating with Service Principal"
    $connectParams['ServicePrincipal'] = $true
    $connectParams['Credential']       = $Credential
    Connect-AzAccount @connectParams | Out-Null
} else {
    Write-Step "Authenticating interactively"
    Connect-AzAccount @connectParams | Out-Null
}

if ($SubscriptionId) {
    Write-Step "Setting subscription context: $SubscriptionId"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$context = Get-AzContext
Write-Step "Connected as: $($context.Account) | Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"

#endregion

#region ── Discover Cluster ─────────────────────────────────────────────────────

Write-Section "Discovering Azure Local cluster"

$clusters = Get-AzStackHciCluster -ResourceGroupName $ResourceGroupName
if (-not $clusters) {
    Write-Error "No Azure Local clusters found in resource group '$ResourceGroupName'."
}

if ($ClusterName) {
    $cluster = $clusters | Where-Object Name -EQ $ClusterName
    if (-not $cluster) {
        Write-Error "Cluster '$ClusterName' not found in '$ResourceGroupName'."
    }
} else {
    $cluster = $clusters | Select-Object -First 1
    Write-Step "No ClusterName specified — using: $($cluster.Name)"
}

$ClusterName = $cluster.Name
Write-Step "Cluster: $ClusterName | Location: $($cluster.Location)"

#endregion

#region ── Gather ARM Data ──────────────────────────────────────────────────────

Write-Section "Gathering ARM data"

# Arc settings
Write-Step "Arc settings"
$arcSettings = $null
try { $arcSettings = Get-AzStackHciArcSetting -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName } catch { }

# Arc extensions
Write-Step "Arc extensions"
$extensions = @()
try { $extensions = @(Get-AzStackHciExtension -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName) } catch { }

# Deployment settings (network intents, IPs, storage paths, AD, DNS)
Write-Step "Deployment settings"
$deploySettings = $null
try { $deploySettings = Get-AzStackHciDeploymentSetting -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName } catch { }

# Security settings
Write-Step "Security settings"
$securitySettings = $null
try {
    $secRes = Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.AzureStackHCI/clusters/securitySettings' `
        -ResourceName "$ClusterName/default" -ApiVersion '2024-04-01' -ErrorAction SilentlyContinue
    $securitySettings = $secRes.Properties
} catch { }

# Logical networks
Write-Step "Logical networks"
$logicalNetworks = @()
try {
    $logicalNetworks = @(Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.AzureStackHCI/logicalNetworks' -ApiVersion '2024-01-01')
} catch { }

# Virtual machine instances
Write-Step "Virtual machine instances"
$vmInstances = @()
try {
    $vmInstances = @(Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.AzureStackHCI/virtualMachineInstances' -ApiVersion '2024-01-01')
} catch { }

# Gallery images
Write-Step "Gallery images"
$galleryImages = @()
try {
    $galleryImages = @(Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.AzureStackHCI/galleryImages' -ApiVersion '2024-01-01')
    $marketImages  = @(Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.AzureStackHCI/marketplaceGalleryImages' -ApiVersion '2024-01-01')
    $galleryImages += $marketImages
} catch { }

# Updates
Write-Step "Updates"
$updates = @()
try { $updates = @(Get-AzStackHciUpdate -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName) } catch { }

#endregion

#region ── Gather On-Node Data (optional) ───────────────────────────────────────

$nodeData = @{}

if ($IncludeNodeData) {
    Write-Section "Gathering on-node data (PowerShell remoting)"

    # Determine node names from cluster or deployment settings
    $nodeNames = @()
    if ($deploySettings -and $deploySettings.Properties.deploymentConfiguration.cluster.nodes) {
        $nodeNames = $deploySettings.Properties.deploymentConfiguration.cluster.nodes | ForEach-Object { $_.name }
    } elseif ($cluster.NodeCount -gt 0) {
        Write-Step "Cannot determine node names from ARM — specify nodes manually if needed"
    }

    if (-not $nodeNames) {
        # Fall back: try to resolve via cluster name conventions or ask
        Write-Warning "Could not determine node names from ARM data. Skipping on-node collection."
    } else {
        $firstNode = $nodeNames | Select-Object -First 1
        Write-Step "Connecting to first node for cluster-wide data: $firstNode"

        $remotingParams = @{ ComputerName = $firstNode }
        if ($NodeCredential) { $remotingParams['Credential'] = $NodeCredential }

        try {
            $nodeData = Invoke-Command @remotingParams -ScriptBlock {
                $result = @{}

                # Storage pools
                try {
                    $pools = Get-StoragePool | Where-Object IsPrimordial -EQ $false
                    $result['StoragePools'] = $pools | ForEach-Object {
                        @{
                            FriendlyName     = $_.FriendlyName
                            OperationalStatus = $_.OperationalStatus
                            TotalSizeGB      = [math]::Round($_.Size / 1GB, 1)
                            AllocatedSizeGB  = [math]::Round($_.AllocatedSize / 1GB, 1)
                        }
                    }
                } catch { $result['StoragePools'] = @() }

                # Volumes
                try {
                    $vols = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.FileSystem -ne '' }
                    $result['Volumes'] = $vols | ForEach-Object {
                        @{
                            FriendlyName  = $_.FileSystemLabel
                            FileSystem    = $_.FileSystem
                            SizeGB        = [math]::Round($_.Size / 1GB, 1)
                            SizeRemainingGB = [math]::Round($_.SizeRemaining / 1GB, 1)
                            HealthStatus  = $_.HealthStatus
                        }
                    }
                } catch { $result['Volumes'] = @() }

                # Physical disks
                try {
                    $disks = Get-PhysicalDisk | Where-Object { $_.CanPool -eq $true -or $_.OperationalStatus -eq 'OK' }
                    $result['PhysicalDisks'] = $disks | ForEach-Object {
                        @{
                            FriendlyName      = $_.FriendlyName
                            MediaType         = $_.MediaType
                            BusType           = $_.BusType
                            SizeGB            = [math]::Round($_.Size / 1GB, 1)
                            OperationalStatus = $_.OperationalStatus
                            HealthStatus      = $_.HealthStatus
                        }
                    }
                } catch { $result['PhysicalDisks'] = @() }

                # Network adapters
                try {
                    $nics = Get-NetAdapter | Where-Object Status -EQ 'Up'
                    $result['NetAdapters'] = $nics | ForEach-Object {
                        @{
                            Name            = $_.Name
                            InterfaceDescription = $_.InterfaceDescription
                            LinkSpeedGbps   = [math]::Round($_.LinkSpeed / 1e9, 0)
                            MacAddress      = $_.MacAddress
                            Status          = $_.Status
                        }
                    }
                } catch { $result['NetAdapters'] = @() }

                # Cluster nodes
                try {
                    $clusterNodes = Get-ClusterNode
                    $result['ClusterNodes'] = $clusterNodes | ForEach-Object {
                        @{
                            Name  = $_.Name
                            State = $_.State
                            Id    = $_.Id
                        }
                    }
                } catch { $result['ClusterNodes'] = @() }

                return $result
            }
            Write-Step "On-node data collected successfully"
        } catch {
            Write-Warning "Failed to collect on-node data from ${firstNode}: $_"
        }
    }
}

#endregion

#region ── Build Markdown Document ──────────────────────────────────────────────

Write-Section "Building documentation"

$generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$sb = [System.Text.StringBuilder]::new()

function Add([string]$Line = '') { $null = $sb.AppendLine($Line) }

# ── Title & metadata ──────────────────────────────────────────────────────────
Add "# Azure Local Cluster Documentation"
Add "**Cluster:** ``$ClusterName``  "
Add "**Resource Group:** ``$ResourceGroupName``  "
Add "**Subscription:** ``$($context.Subscription.Name)`` (``$($context.Subscription.Id)``)  "
Add "**Generated:** $generatedAt by Get-AzLocalDoc  "
Add ""
Add "---"
Add ""
Add "## Table of Contents"
Add ""
Add "1. [Cluster Overview](#1-cluster-overview)"
Add "2. [Deployment Configuration](#2-deployment-configuration)"
Add "3. [Network Configuration](#3-network-configuration)"
Add "4. [Storage Configuration](#4-storage-configuration)"
Add "5. [Identity & Security](#5-identity--security)"
Add "6. [Azure Arc & Extensions](#6-azure-arc--extensions)"
Add "7. [Logical Networks](#7-logical-networks)"
Add "8. [Virtual Machines & Images](#8-virtual-machines--images)"
Add "9. [Updates](#9-updates)"
if ($IncludeNodeData -and $nodeData.Count -gt 0) {
    Add "10. [On-Node Data](#10-on-node-data)"
}
Add ""
Add "---"
Add ""

# ── 1. Cluster Overview ───────────────────────────────────────────────────────
Add "## 1. Cluster Overview"
Add ""
$clusterProps = [ordered]@{
    'Name'                = Safe $cluster.Name
    'Location'            = Safe $cluster.Location
    'Cloud Management Endpoint' = Safe $cluster.CloudManagementEndpoint
    'Software Version'    = Safe $cluster.CloudId
    'Service Endpoint'    = Safe $cluster.ServiceEndpoint
    'Registration Status' = Safe $cluster.RegistrationTimestamp
    'Connectivity Status' = Safe $cluster.ConnectivityStatus
    'Last Sync'           = Safe $cluster.LastSyncTimestamp
    'Desired Properties'  = Safe ($cluster.DesiredProperties | ConvertTo-Json -Compress)
    'Tags'                = if ($cluster.Tag) { ($cluster.Tag.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' } else { 'None' }
}
Add (Format-PropTable-Md $clusterProps)
Add ""

# ── 2. Deployment Configuration ───────────────────────────────────────────────
Add "## 2. Deployment Configuration"
Add ""
if ($deploySettings) {
    $dc = $deploySettings.Properties.deploymentConfiguration

    # Cluster-level
    if ($dc.cluster) {
        Add "### Cluster Settings"
        Add ""
        $clusterSettingsRows = @(
            @('Cluster Name', (Safe $dc.cluster.name)),
            @('Witness Type', (Safe $dc.cluster.witnessType)),
            @('Witness Path', (Safe $dc.cluster.witnessPath)),
            @('Cloud ID', (Safe $dc.cluster.cloudAccountName))
        )
        Add (Format-Table-Md -Headers @('Setting','Value') -Rows $clusterSettingsRows)
        Add ""
    }

    # Nodes
    if ($dc.cluster.nodes) {
        Add "### Nodes"
        Add ""
        $nodeRows = $dc.cluster.nodes | ForEach-Object {
            @(
                (Safe $_.name),
                (Safe $_.ipv4Address),
                (Safe $_.windowsServerSubscription),
                (Safe $_.adapterNameOverride)
            )
        }
        Add (Format-Table-Md -Headers @('Node Name', 'IP Address', 'WS Subscription', 'Adapter Override') -Rows $nodeRows)
        Add ""
    }

    # Infrastructure network
    if ($dc.infrastructureNetwork) {
        Add "### Infrastructure Network"
        Add ""
        $infra = $dc.infrastructureNetwork | Select-Object -First 1
        $infraRows = @(
            @('Starting Address', (Safe $infra.startingAddress)),
            @('Ending Address',   (Safe $infra.endingAddress)),
            @('Gateway',          (Safe $infra.gateway)),
            @('Subnet Mask',      (Safe $infra.subnetMask)),
            @('DNS Servers',      (Safe ($infra.dnsServers -join ', ')))
        )
        Add (Format-Table-Md -Headers @('Setting','Value') -Rows $infraRows)
        Add ""
    }

    # Network intents
    if ($dc.networkIntent) {
        Add "### Network Intents"
        Add ""
        foreach ($intent in $dc.networkIntent) {
            Add "#### Intent: ``$($intent.name)``"
            Add ""
            $intentRows = @(
                @('Traffic Type', (Safe ($intent.trafficType -join ', '))),
                @('Adapter Names', (Safe ($intent.adapter -join ', '))),
                @('Override VLAN IDs', (Safe ($intent.adapterPropertyOverrides.jumboPacket))),
                @('RDMA Enabled', (Safe $intent.adapterPropertyOverrides.networkDirect)),
                @('Switch Embedded Teaming', (Safe $intent.adapterPropertyOverrides.networkDirectTechnology))
            )
            Add (Format-Table-Md -Headers @('Property','Value') -Rows $intentRows)
            Add ""
        }
    }

    # Storage (path info)
    if ($dc.storage) {
        Add "### Storage Paths"
        Add ""
        if ($dc.storage.configurationMode) {
            Add "**Configuration Mode:** ``$($dc.storage.configurationMode)``"
            Add ""
        }
        if ($dc.storage.sataPath -or $dc.storage.nvmePath) {
            $storRows = @(
                @('SATA Path', (Safe $dc.storage.sataPath)),
                @('NVMe Path', (Safe $dc.storage.nvmePath))
            )
            Add (Format-Table-Md -Headers @('Type','Path') -Rows $storRows)
            Add ""
        }
    }

} else {
    Add "_Deployment settings not available (cluster may be in a legacy registration state)._"
    Add ""
}

# ── 3. Network Configuration ──────────────────────────────────────────────────
Add "## 3. Network Configuration"
Add ""
if ($deploySettings -and $deploySettings.Properties.deploymentConfiguration.hostNetwork) {
    $hn = $deploySettings.Properties.deploymentConfiguration.hostNetwork
    $hnRows = @(
        @('Enable RDMA', (Safe $hn.enableStorageAutoIp)),
        @('Intents Count', (Safe ($deploySettings.Properties.deploymentConfiguration.networkIntent | Measure-Object).Count))
    )
    Add (Format-Table-Md -Headers @('Property','Value') -Rows $hnRows)
    Add ""
} else {
    Add "_Detailed host network config available in the Network Intents section above._"
    Add ""
}

# ── 4. Storage Configuration ──────────────────────────────────────────────────
Add "## 4. Storage Configuration"
Add ""
if ($nodeData.StoragePools -and $nodeData.StoragePools.Count -gt 0) {
    Add "### Storage Pools"
    Add ""
    $poolRows = $nodeData.StoragePools | ForEach-Object {
        @(
            (Safe $_['FriendlyName']),
            (Safe $_['OperationalStatus']),
            "$($_.TotalSizeGB) GB",
            "$($_.AllocatedSizeGB) GB"
        )
    }
    Add (Format-Table-Md -Headers @('Pool Name','Status','Total (GB)','Allocated (GB)') -Rows $poolRows)
    Add ""

    if ($nodeData.Volumes -and $nodeData.Volumes.Count -gt 0) {
        Add "### Volumes"
        Add ""
        $volRows = $nodeData.Volumes | ForEach-Object {
            @(
                (Safe $_['FriendlyName']),
                (Safe $_['FileSystem']),
                "$($_['SizeGB']) GB",
                "$($_['SizeRemainingGB']) GB",
                (Safe $_['HealthStatus'])
            )
        }
        Add (Format-Table-Md -Headers @('Label','File System','Size (GB)','Free (GB)','Health') -Rows $volRows)
        Add ""
    }

    if ($nodeData.PhysicalDisks -and $nodeData.PhysicalDisks.Count -gt 0) {
        Add "### Physical Disks (sampled from first node)"
        Add ""
        $diskRows = $nodeData.PhysicalDisks | ForEach-Object {
            @(
                (Safe $_['FriendlyName']),
                (Safe $_['MediaType']),
                (Safe $_['BusType']),
                "$($_['SizeGB']) GB",
                (Safe $_['OperationalStatus'])
            )
        }
        Add (Format-Table-Md -Headers @('Model','Media','Bus','Size (GB)','Status') -Rows $diskRows)
        Add ""
    }
} else {
    Add "_Storage pool data not collected. Run with ``-IncludeNodeData`` to include on-node storage details._"
    Add ""
}

# ── 5. Identity & Security ────────────────────────────────────────────────────
Add "## 5. Identity & Security"
Add ""

$idRows = @(
    @('AAD Tenant ID',     (Safe $cluster.AadTenantId)),
    @('AAD Client ID',     (Safe $cluster.AadClientId)),
    @('AAD App Object ID', (Safe $cluster.AadApplicationObjectId)),
    @('AAD SP Object ID',  (Safe $cluster.AadServicePrincipalObjectId))
)
Add (Format-Table-Md -Headers @('Property','Value') -Rows $idRows)
Add ""

if ($deploySettings -and $deploySettings.Properties.deploymentConfiguration.adouPath) {
    Add "**Active Directory OU Path:** ``$($deploySettings.Properties.deploymentConfiguration.adouPath)``  "
    Add "**Domain:** ``$($deploySettings.Properties.deploymentConfiguration.domainFqdn)``  "
    Add ""
}

if ($securitySettings) {
    Add "### Security Settings"
    Add ""
    $secRows = $securitySettings.PSObject.Properties | ForEach-Object {
        @($_.Name, (Safe $_.Value))
    }
    if ($secRows) {
        Add (Format-Table-Md -Headers @('Setting','Value') -Rows $secRows)
    } else {
        Add "_No detailed security properties returned._"
    }
    Add ""
}

# ── 6. Azure Arc & Extensions ─────────────────────────────────────────────────
Add "## 6. Azure Arc & Extensions"
Add ""

if ($arcSettings) {
    $arcRows = @(
        @('Arc Instance ID', (Safe $arcSettings.ArcInstanceResourceGroup)),
        @('Connectivity Status', (Safe $arcSettings.ConnectivityStatus)),
        @('Arc Application Object ID', (Safe $arcSettings.ArcApplicationObjectId)),
        @('Arc Service Principal Object ID', (Safe $arcSettings.ArcServicePrincipalObjectId))
    )
    Add (Format-Table-Md -Headers @('Property','Value') -Rows $arcRows)
    Add ""
}

if ($extensions.Count -gt 0) {
    Add "### Installed Arc Extensions"
    Add ""
    $extRows = $extensions | ForEach-Object {
        @(
            (Safe $_.Name),
            (Safe $_.ExtensionParameters.type),
            (Safe $_.ExtensionParameters.typeHandlerVersion),
            (Safe $_.ProvisioningState),
            (Safe $_.ManagedBy)
        )
    }
    Add (Format-Table-Md -Headers @('Name','Type','Version','Provisioning State','Managed By') -Rows $extRows)
} else {
    Add "_No Arc extensions found or accessible._"
}
Add ""

# ── 7. Logical Networks ───────────────────────────────────────────────────────
Add "## 7. Logical Networks"
Add ""

if ($logicalNetworks.Count -gt 0) {
    foreach ($net in $logicalNetworks) {
        Add "### ``$($net.Name)``"
        Add ""
        $netProps = $net.Properties
        $netRows = @(
            @('VM Switch Name',  (Safe $netProps.vmSwitchName)),
            @('Provisioning State', (Safe $netProps.provisioningState))
        )
        Add (Format-Table-Md -Headers @('Property','Value') -Rows $netRows)
        Add ""

        if ($netProps.subnets) {
            Add "**Subnets:**"
            Add ""
            $subnetRows = $netProps.subnets | ForEach-Object {
                @(
                    (Safe $_.name),
                    (Safe $_.properties.addressPrefix),
                    (Safe $_.properties.ipAllocationMethod),
                    (Safe $_.properties.vlan)
                )
            }
            Add (Format-Table-Md -Headers @('Subnet Name','CIDR','Allocation','VLAN') -Rows $subnetRows)
            Add ""
        }
    }
} else {
    Add "_No logical networks found in this resource group._"
    Add ""
}

# ── 8. Virtual Machines & Images ──────────────────────────────────────────────
Add "## 8. Virtual Machines & Images"
Add ""

if ($vmInstances.Count -gt 0) {
    Add "### Virtual Machine Instances"
    Add ""
    $vmRows = $vmInstances | ForEach-Object {
        @(
            (Safe $_.Name),
            (Safe $_.Location),
            (Safe $_.Properties.provisioningState)
        )
    }
    Add (Format-Table-Md -Headers @('Name','Location','State') -Rows $vmRows)
    Add ""
} else {
    Add "_No virtual machine instances found._"
    Add ""
}

if ($galleryImages.Count -gt 0) {
    Add "### Available Images"
    Add ""
    $imgRows = $galleryImages | ForEach-Object {
        @(
            (Safe $_.Name),
            (Safe $_.ResourceType.Split('/')[-1]),
            (Safe $_.Properties.osType),
            (Safe $_.Properties.hyperVGeneration),
            (Safe $_.Properties.provisioningState)
        )
    }
    Add (Format-Table-Md -Headers @('Name','Source','OS Type','Hyper-V Gen','State') -Rows $imgRows)
    Add ""
}

# ── 9. Updates ────────────────────────────────────────────────────────────────
Add "## 9. Updates"
Add ""

if ($updates.Count -gt 0) {
    $recentUpdates = $updates | Sort-Object { $_.AvailabilityType } | Select-Object -First 20
    $updateRows = $recentUpdates | ForEach-Object {
        @(
            (Safe $_.DisplayName),
            (Safe $_.Version),
            (Safe $_.State),
            (Safe $_.AvailabilityType),
            (Safe $_.ReleaseLink)
        )
    }
    Add (Format-Table-Md -Headers @('Name','Version','State','Availability','Release Notes') -Rows $updateRows)
} else {
    Add "_No update records found or update service not accessible._"
}
Add ""

# ── 10. On-Node Data ──────────────────────────────────────────────────────────
if ($IncludeNodeData -and $nodeData.Count -gt 0) {
    Add "## 10. On-Node Data"
    Add ""
    Add "> Collected via PowerShell remoting from first cluster node."
    Add ""

    if ($nodeData.ClusterNodes) {
        Add "### Cluster Nodes"
        Add ""
        $cnRows = $nodeData.ClusterNodes | ForEach-Object {
            @((Safe $_['Name']), (Safe $_['State']), (Safe $_['Id']))
        }
        Add (Format-Table-Md -Headers @('Name','State','ID') -Rows $cnRows)
        Add ""
    }

    if ($nodeData.NetAdapters -and $nodeData.NetAdapters.Count -gt 0) {
        Add "### Network Adapters (first node, active only)"
        Add ""
        $nicRows = $nodeData.NetAdapters | ForEach-Object {
            @(
                (Safe $_['Name']),
                (Safe $_['InterfaceDescription']),
                "$($_['LinkSpeedGbps']) Gbps",
                (Safe $_['MacAddress'])
            )
        }
        Add (Format-Table-Md -Headers @('Name','Description','Speed','MAC Address') -Rows $nicRows)
        Add ""
    }
}

# ── Footer ────────────────────────────────────────────────────────────────────
Add "---"
Add ""
Add "_Generated by [Get-AzLocalDoc](https://github.com/chkja/Get-AzLocalDoc) — $generatedAt_"
Add ""

#endregion

#region ── Write Output ─────────────────────────────────────────────────────────

if (-not $OutputPath) {
    $safeName  = $ClusterName -replace '[^a-zA-Z0-9\-]', '_'
    $dateStamp = Get-Date -Format 'yyyyMMdd'
    $OutputPath = ".\${safeName}-doc-${dateStamp}.md"
}

$markdownContent = $sb.ToString()
$markdownContent | Set-Content -Path $OutputPath -Encoding UTF8

Write-Host ""
Write-Host "✅ Documentation written to: $OutputPath" -ForegroundColor Green
Write-Host "   $(($markdownContent -split "`n").Count) lines | $([math]::Round($markdownContent.Length / 1KB, 1)) KB"

#endregion
