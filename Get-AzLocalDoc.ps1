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
    The name of the Azure Local cluster. If omitted and the resource group contains
    exactly one cluster, it is used automatically. If multiple clusters exist you will
    be prompted to select one interactively.

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
      - PowerShell 7.0 or later (pwsh)
      - Az.Accounts, Az.Resources, Az.StackHCI PowerShell modules
      - On-node sections additionally require the FailoverClusters and S2D modules
        installed on the HCI nodes
#>
#Requires -Version 7.0

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

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$env:SuppressAzurePowerShellBreakingChangeWarnings = 'true'   # suppress Az module deprecation notices
Update-AzConfig -DisplayBreakingChangeWarning $false -ErrorAction SilentlyContinue | Out-Null

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
    param([string[]]$Headers, $Rows)
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('| ' + ($Headers -join ' | ') + ' |')
    $null = $sb.AppendLine('| ' + (($Headers | ForEach-Object { '---' }) -join ' | ') + ' |')
    $colCount = $Headers.Count
    # Detect flat array (each element is a scalar, not an array) and chunk by column count
    $flat = ($Rows.Count -gt 0 -and $Rows[0] -isnot [System.Array])
    if ($flat) {
        for ($i = 0; $i -lt $Rows.Count; $i += $colCount) {
            $row = $Rows[$i..([Math]::Min($i + $colCount - 1, $Rows.Count - 1))]
            $null = $sb.AppendLine('| ' + ($row -join ' | ') + ' |')
        }
    } else {
        foreach ($row in $Rows) {
            $null = $sb.AppendLine('| ' + ($row -join ' | ') + ' |')
        }
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
if ($TenantId) { $connectParams['TenantId'] = $TenantId }

if ($ServicePrincipal) {
    Write-Step "Authenticating with Service Principal"
    $connectParams['ServicePrincipal'] = $true
    $connectParams['Credential']       = $Credential
    Connect-AzAccount @connectParams | Out-Null
} else {
    $context = Get-AzContext
    $tenantMatch = -not $TenantId -or ($context -and $context.Tenant.Id -eq $TenantId)
    if ($context -and $context.Account -and $tenantMatch) {
        Write-Step "Reusing existing context: $($context.Account) | $($context.Subscription.Name)"
    } else {
        Write-Step "No active session found — authenticating interactively"
        Connect-AzAccount @connectParams | Out-Null
    }
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

$clusters = @(Get-AzStackHciCluster -ResourceGroupName $ResourceGroupName)
if (-not $clusters) {
    Write-Error "No Azure Local clusters found in resource group '$ResourceGroupName'."
}

if ($ClusterName) {
    $cluster = $clusters | Where-Object Name -EQ $ClusterName
    if (-not $cluster) {
        Write-Error "Cluster '$ClusterName' not found in '$ResourceGroupName'. Available: $($clusters.Name -join ', ')"
        exit 1
    }
} elseif ($clusters.Count -eq 1) {
    $cluster = $clusters[0]
    Write-Step "One cluster found — using: $($cluster.Name)"
} else {
    # Multiple clusters found — prompt for selection
    Write-Host ""
    Write-Host "  Multiple Azure Local clusters found in '$ResourceGroupName':" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $clusters.Count; $i++) {
        Write-Host ("  [{0}] {1,-40} {2}" -f ($i + 1), $clusters[$i].Name, $clusters[$i].Location)
    }
    Write-Host ""
    do {
        $selection = Read-Host "  Select cluster [1-$($clusters.Count)]"
        $idx = [int]$selection - 1
    } while ($idx -lt 0 -or $idx -ge $clusters.Count)
    $cluster = $clusters[$idx]
    Write-Step "Selected: $($cluster.Name)"
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
try { $extensions = @(Get-AzStackHciExtension -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName -ArcSettingName "default") } catch { }

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
    $securitySettings = if ($secRes -and $secRes.PSObject.Properties['Properties']) { $secRes.Properties } else { $null }
} catch { }

# Custom Location & Arc Resource Bridge (needed before VM query)
Write-Step "Custom location & resource bridge"
$customLocation  = $null
$resourceBridge  = $null
try { $customLocation = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.ExtendedLocation/customLocations' -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }
try {
    $resourceBridge = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.ResourceConnector/appliances' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $resourceBridge) {
        $resourceBridge = Get-AzResource -ResourceType 'Microsoft.ResourceConnector/appliances' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$ClusterName*" -or $_.ResourceGroupName -like "*$ResourceGroupName*" } |
            Select-Object -First 1
    }
} catch { }

# Logical networks
Write-Step "Logical networks"
$logicalNetworks = @()
try {
    $logicalNetworks = @(Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.AzureStackHCI/logicalNetworks' -ExpandProperties)
} catch { }

# Virtual machine instances — may span multiple resource groups and subscriptions
Write-Step "Virtual machine instances"
$vmInstances = @()
try {
    $subId = $context.Subscription.Id
    # Get all subscriptions accessible to the current identity
    $allSubscriptions = @(Get-AzSubscription -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if ($allSubscriptions.Count -eq 0) { $allSubscriptions = @($subId) }
    Write-Step "Searching $($allSubscriptions.Count) subscription(s) for VM instances"

    # Pre-build HCI node name exclusion list
    $hciNodeNames = @()
    if ($deploySettings -and $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataPhysicalNode) {
        $hciNodeNames = @($deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataPhysicalNode |
            ForEach-Object { $_.Name.ToLower() })
    }

    foreach ($searchSubId in $allSubscriptions) {
        $uri      = "/subscriptions/$searchSubId/providers/Microsoft.HybridCompute/machines?api-version=2024-05-20-preview"
        $machResp = Invoke-AzRestMethod -Method GET -Path $uri
        if ($machResp.StatusCode -ne 200) { continue }
        $machines  = ($machResp.Content | ConvertFrom-Json).value
        $candidates = $machines | Where-Object {
            $mRg = if ($_.id -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { '' }
            $_.name.ToLower() -notin $hciNodeNames -and
            $mRg.ToLower() -ne $ResourceGroupName.ToLower()
        }
        foreach ($m in $candidates) {
            $mRg  = if ($m.id -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { 'N/A' }
            $mSub = if ($m.id -match '/subscriptions/([^/]+)/') { $Matches[1] } else { $searchSubId }
            $mLoc = if ($m.PSObject.Properties['location']) { $m.location } else { 'N/A' }
            $vmPath = "$($m.id)/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default?api-version=2024-01-01"
            $vmResp = Invoke-AzRestMethod -Method GET -Path $vmPath
            if ($vmResp.StatusCode -eq 200) {
                $vmObj = $vmResp.Content | ConvertFrom-Json
                if ($customLocation) {
                    $vmEl = if ($vmObj.PSObject.Properties['extendedLocation']) { $vmObj.extendedLocation } else { $null }
                    if (-not $vmEl -or $vmEl.name.ToLower() -ne $customLocation.ResourceId.ToLower()) { continue }
                }
                $vmObj | Add-Member -NotePropertyName '_machineName'    -NotePropertyValue $m.name  -Force
                $vmObj | Add-Member -NotePropertyName '_resourceGroup'  -NotePropertyValue $mRg     -Force
                $vmObj | Add-Member -NotePropertyName '_subscription'   -NotePropertyValue $mSub    -Force
                $vmObj | Add-Member -NotePropertyName '_location'       -NotePropertyValue $mLoc    -Force
                $vmInstances += $vmObj
            }
        }
    }
    Write-Step "Found $($vmInstances.Count) VM instance(s) across all subscriptions"
} catch {
    Write-Warning "VM query failed: $_"
}

# Gallery images
Write-Step "Gallery images"
$galleryImages = @()
try {
    $galleryImages = @(Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.AzureStackHCI/galleryImages' -ExpandProperties)
    $marketImages  = @(Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.AzureStackHCI/marketplaceGalleryImages' -ExpandProperties)
    $galleryImages += $marketImages
} catch { }

# Defender for Cloud
Write-Step "Defender for Cloud"
$defenderPricings = @()
try {
    $defResp = Invoke-AzRestMethod -Method GET `
        -Path "/subscriptions/$($context.Subscription.Id)/providers/Microsoft.Security/pricings?api-version=2023-01-01"
    if ($defResp.StatusCode -eq 200) {
        $relevantPlans = @('HybridCompute','Containers','VirtualMachines','SqlServerVirtualMachines','KubernetesService','Dns','StorageAccounts')
        $defenderPricings = @(($defResp.Content | ConvertFrom-Json).value |
            Where-Object { $_.name -in $relevantPlans })
    }
} catch { }

# Monitoring / Insights
Write-Step "Monitoring"
$monitoringEnabled = $false
$monitorAgentExt = $null
$dcrList = @()
# Check for AzureMonitorWindowsAgent in extensions (signals Insights is configured)
$monitorAgentExt = $extensions | Where-Object { $_.Name -match 'AzureMonitorWindowsAgent' } | Select-Object -First 1
# Query Data Collection Rules in this resource group
try {
    $dcrResp = Invoke-AzRestMethod -Method GET `
        -Path "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules?api-version=2023-03-11"
    if ($dcrResp.StatusCode -eq 200) {
        $dcrList = @(($dcrResp.Content | ConvertFrom-Json).value)
    }
} catch { }
if ($monitorAgentExt -or $dcrList.Count -gt 0) { $monitoringEnabled = $true }

# Updates
Write-Step "Updates"
$updates = @()
try { $updates = @(Get-AzStackHciUpdate -ResourceGroupName $ResourceGroupName -ClusterName $ClusterName) } catch { }

# Network Security Groups
Write-Step "Network Security Groups"
$nsgList = @()
try {
    $nsgApiVersions = @('2024-02-01-preview','2024-05-01-preview','2024-08-01-preview','2024-10-01-preview')
    foreach ($apiVer in $nsgApiVersions) {
        $nsgResp = Invoke-AzRestMethod -Method GET -Path `
            "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/networkSecurityGroups?api-version=$apiVer"
        if ($nsgResp.StatusCode -eq 200) {
            $listParsed = $nsgResp.Content | ConvertFrom-Json
            if ($listParsed.PSObject.Properties['value'] -and $listParsed.value) {
        # Fetch each NSG individually — the list endpoint omits subnet/NIC attachments
                # Also fetch security rules as child resources
                $nsgList = @($listParsed.value | Where-Object { $_ } | ForEach-Object {
                    $single = Invoke-AzRestMethod -Method GET -Path "$($_.id)?api-version=$apiVer" -ErrorAction SilentlyContinue
                    $nsgObj = if ($single -and $single.StatusCode -eq 200) { $single.Content | ConvertFrom-Json } else { $_ }
                    $rulesResp = Invoke-AzRestMethod -Method GET -Path "$($_.id)/securityRules?api-version=$apiVer" -ErrorAction SilentlyContinue
                    $secRules = @()
                    if ($rulesResp -and $rulesResp.StatusCode -eq 200) {
                        $rulesParsed = $rulesResp.Content | ConvertFrom-Json
                        if ($rulesParsed.PSObject.Properties['value'] -and $rulesParsed.value) {
                            $secRules = @($rulesParsed.value | Where-Object { $_ })
                        }
                    }
                    # Attach rules as extra property for render
                    $nsgObj | Add-Member -NotePropertyName '_securityRules' -NotePropertyValue $secRules -Force
                    $nsgObj
                })
            }
            break
        }
    }
} catch { }

# GPU resources (preview)
Write-Step "GPU"
$gpuResources = @()
try {
    $gpuDriverResp = Invoke-AzRestMethod -Method GET `
        -Path "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/gpuDriverInstances?api-version=2024-02-15-preview"
    if ($gpuDriverResp.StatusCode -eq 200) {
        $gpuResources = @(($gpuDriverResp.Content | ConvertFrom-Json).value | Where-Object { $_ })
    }
} catch { }

# Kubernetes clusters (AKS Arc + connected clusters)
Write-Step "Kubernetes clusters"
$k8sClusters = @()
try {
    $k8sClusters = @(
        @(
            Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.Kubernetes/connectedClusters'          -ExpandProperties -ErrorAction SilentlyContinue
            Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.HybridContainerService/provisionedClusters' -ExpandProperties -ErrorAction SilentlyContinue
            Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.ContainerService/managedClusters'      -ExpandProperties -ErrorAction SilentlyContinue
        ) | Where-Object { $_ }
    )
} catch { }

#endregion

#region ── Gather On-Node Data (optional) ───────────────────────────────────────

$nodeData  = @{}
$firstNode = $null

if ($IncludeNodeData) {
    Write-Section "Gathering on-node data (PowerShell remoting)"

    # Determine node names from cluster or deployment settings
    $nodeNames = @()
    if ($deploySettings -and $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataPhysicalNode) {
        $nodeNames = $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataPhysicalNode | ForEach-Object { $_.Name }
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
                    $result['StoragePools'] = @($pools | ForEach-Object {
                        @{
                            FriendlyName      = $_.FriendlyName
                            OperationalStatus = $_.OperationalStatus.ToString()
                            TotalSizeGB       = [math]::Round($_.Size / 1GB, 1)
                            AllocatedSizeGB   = [math]::Round($_.AllocatedSize / 1GB, 1)
                        }
                    })
                } catch { $result['StoragePools'] = @() }

                # Volumes
                try {
                    $vols = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.FileSystem -ne '' }
                    $result['Volumes'] = @($vols | ForEach-Object {
                        @{
                            FriendlyName    = $_.FileSystemLabel
                            FileSystem      = $_.FileSystem
                            SizeGB          = [math]::Round($_.Size / 1GB, 1)
                            SizeRemainingGB = [math]::Round($_.SizeRemaining / 1GB, 1)
                            HealthStatus    = $_.HealthStatus.ToString()
                        }
                    })
                } catch { $result['Volumes'] = @() }

                # Physical disks
                try {
                    $disks = Get-PhysicalDisk | Where-Object { $_.CanPool -eq $true -or $_.OperationalStatus -eq 'OK' }
                    $result['PhysicalDisks'] = @($disks | ForEach-Object {
                        @{
                            FriendlyName      = $_.FriendlyName
                            MediaType         = $_.MediaType.ToString()
                            BusType           = $_.BusType.ToString()
                            SizeGB            = [math]::Round($_.Size / 1GB, 1)
                            OperationalStatus = $_.OperationalStatus.ToString()
                            HealthStatus      = $_.HealthStatus.ToString()
                        }
                    })
                } catch { $result['PhysicalDisks'] = @() }

                # Network adapters
                try {
                    $nics = Get-NetAdapter | Where-Object Status -EQ 'Up'
                    $result['NetAdapters'] = @($nics | ForEach-Object {
                        @{
                            Name                 = $_.Name
                            InterfaceDescription = $_.InterfaceDescription
                            LinkSpeed            = $_.LinkSpeed
                            MacAddress           = $_.MacAddress
                            Status               = $_.Status.ToString()
                        }
                    })
                } catch { $result['NetAdapters'] = @() }

                # Cluster nodes
                try {
                    $clusterNodes = Get-ClusterNode
                    $result['ClusterNodes'] = @($clusterNodes | ForEach-Object {
                        @{
                            Name  = $_.Name
                            State = $_.State.ToString()
                            Id    = $_.Id
                        }
                    })
                } catch { $result['ClusterNodes'] = @() }

                # Local administrators group
                try {
                    $admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
                    $result['LocalAdmins'] = @($admins | ForEach-Object {
                        @{
                            Name            = $_.Name
                            ObjectClass     = $_.ObjectClass
                            PrincipalSource = $_.PrincipalSource.ToString()
                        }
                    })
                } catch { $result['LocalAdmins'] = @() }

                # GPU hardware detection
                try {
                    $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
                        Where-Object { $_.Name -notmatch 'Basic|Standard|Remote|Hyper-V' }
                    $result['GPUs'] = @($gpus | ForEach-Object {
                        @{
                            Name          = $_.Name
                            DriverVersion = $_.DriverVersion
                            Status        = $_.Status
                            AdapterRAMGB  = if ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1GB, 1) } else { 'N/A' }
                        }
                    })
                } catch { $result['GPUs'] = @() }

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

$generatedAt    = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
$generatedShort = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$sb = [System.Text.StringBuilder]::new()

function Add([string]$Line = '') { $null = $sb.AppendLine($Line) }

# Helper: connectivity status badge (style: ✓ / ⚠)
function StatusBadge([string]$status) {
    if ($status -match 'Connected|Succeeded|Running|Enabled|True|^Up$|^OK$|^Healthy$') { return "✓ $status" }
    if ($status -match 'Disconnected|Failed|Error|Disabled|False') { return "⚠ $status" }
    return $status
}

# ── Title ─────────────────────────────────────────────────────────────────────
Add "# Azure Local Configuration Report"
Add ""
Add "**Cluster:** ``$ClusterName``  "
Add "**Resource Group:** ``$ResourceGroupName``  "
Add "**Subscription:** $($context.Subscription.Name) (``$($context.Subscription.Id)``)  "
Add "**Location:** $(Safe $cluster.Location)  "
Add "**Generated:** $generatedShort  "
Add "**Data Sources:** Azure ARM$(if ($IncludeNodeData -and $firstNode) { " + PowerShell remoting (``$firstNode``)" } else { " only" })  "
Add ""
Add "---"
Add ""
Add "## Table of Contents"
Add ""
Add "- [Report Metadata](#report-metadata)"
Add "- [Validation Summary](#validation-summary)"
Add "- [Configuration Summary](#configuration-summary)"
Add "  - [Deployment Scenario & Scale](#deployment-scenario--scale)"
Add "  - [Node Configuration](#node-configuration)"
Add "  - [Network Configuration](#network-configuration)"
Add "  - [Active Directory Configuration](#active-directory-configuration)"
Add "  - [Security Configuration](#security-configuration)"
Add "  - [Microsoft Defender for Cloud](#microsoft-defender-for-cloud)"
Add "  - [Billing & Licensing](#billing--licensing)"
Add "  - [Monitoring & Insights](#monitoring--insights)"
Add "- [Workloads & Platform Configuration](#workloads--platform-configuration)"
Add "  - [Azure Arc & Extensions](#azure-arc--extensions)"
Add "  - [Virtual Machines & Images](#virtual-machines--images)"
Add "  - [Kubernetes Clusters](#kubernetes-clusters)"
Add "  - [Updates](#updates)"
Add "  - [Storage Configuration](#storage-configuration)"
Add ""
Add "---"
Add ""
Add "## Report Metadata"
Add ""
$metaRows = @(
    @('Cluster Name',          "``$(Safe $cluster.Name)``"),
    @('Location',              (Safe $cluster.Location)),
    @('Connectivity Status',   (StatusBadge (Safe $cluster.ConnectivityStatus))),
    @('Cluster Status',        (StatusBadge (Safe $cluster.Status))),
    @('Provisioning State',    (StatusBadge (Safe $cluster.ProvisioningState))),
    @('Cluster Version',       (Safe $cluster.ReportedPropertyClusterVersion)),
    @('OS Display Version',    $(
        $_n = if ($cluster.ReportedPropertyNode) { @($cluster.ReportedPropertyNode)[0] } else { $null }
        if ($_n -and $_n.PSObject.Properties['osDisplayVersion']) { $_n.osDisplayVersion } else { 'N/A' }
    )),
    @('Manufacturer',          (Safe $cluster.ReportedPropertyManufacturer)),
    @('Cluster Type',          (Safe $cluster.ReportedPropertyClusterType)),
    @('Billing Model',         (Safe $cluster.BillingModel)),
    @('Trial Days Remaining',  (Safe $cluster.TrialDaysRemaining)),
    @('Last Billing',          (Safe $cluster.LastBillingTimestamp)),
    @('Registration Date',     (Safe $cluster.RegistrationTimestamp)),
    @('Last Sync',             (Safe $cluster.LastSyncTimestamp)),
    @('IMDS Attestation',      (StatusBadge (Safe $cluster.ReportedPropertyImdsAttestation))),
    @('Diagnostic Level',      (Safe $cluster.ReportedPropertyDiagnosticLevel)),
    @('Azure Portal URL',      "https://portal.azure.com/#resource$($cluster.Id)/overview"),
    @('Service Endpoint',      "``$(Safe $cluster.ServiceEndpoint)``"),
    @('Cluster ID (CloudId)',   (Safe $cluster.CloudId)),
    @('AAD Tenant ID',         "``$(Safe $cluster.AadTenantId)``"),
    @('Custom Location',       $(if ($customLocation)  { "``$($customLocation.Name)``"  } else { 'N/A' })),
    @('Arc Resource Bridge',   $(if ($resourceBridge)  { "``$($resourceBridge.Name)``$(if ($resourceBridge.ResourceGroupName -ne $ResourceGroupName) { " *(RG: $($resourceBridge.ResourceGroupName))*" })" } else { 'N/A' })),
    @('Tags',                  $(
        $tagPairs = $cluster.Tag.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { "$($_.Name)=$($_.Value)" }
        if ($tagPairs) { $tagPairs -join ', ' } else { 'None' }
    ))
)
Add (Format-Table-Md -Headers @('Property','Value') -Rows $metaRows)
Add ""

# ── R4 Validation Summary ─────────────────────────────────────────────────────
Add "---"
Add ""
Add "## Validation Summary"
Add ""
Add "> This section reflects the **observed state** of the cluster at report generation time."
Add ""

$valRows = @()

# Cluster connectivity
$connStatus = Safe $cluster.ConnectivityStatus
$valRows += ,@((StatusBadge $connStatus), 'Cluster Connectivity', $connStatus)

# Provisioning state
$provState = Safe $cluster.ProvisioningState
$valRows += ,@((StatusBadge $provState), 'Cluster Provisioning State', $provState)

# Arc settings
if ($arcSettings) {
    $arcState = Safe $arcSettings.AggregateState
    $valRows += ,@((StatusBadge $arcState), 'Arc Aggregate State', $arcState)
} else {
    $valRows += ,@('⚠ Not available', 'Arc Settings', 'Could not retrieve Arc settings')
}

# Extensions
if ($extensions.Count -gt 0) {
    $failedExt = @($extensions | Where-Object { $_.ProvisioningState -notmatch 'Succeeded' })
    if ($failedExt) {
        $valRows += ,@("⚠ $($failedExt.Count) issue(s)", 'Arc Extensions', ($failedExt | ForEach-Object { $_.Name }) -join ', ')
    } else {
        $valRows += ,@("✓ All healthy", 'Arc Extensions', "$($extensions.Count) extension(s) provisioned successfully")
    }
} else {
    $valRows += ,@('— None found', 'Arc Extensions', 'No extensions installed or accessible')
}

# Updates
if ($updates.Count -gt 0) {
    $available = @($updates | Where-Object { $_.State -match 'Available|Ready' })
    if ($available) {
        $valRows += ,@("⚠ $($available.Count) available", 'Updates', ($available | Select-Object -First 3 -ExpandProperty DisplayName) -join ', ')
    } else {
        $valRows += ,@('✓ Up to date', 'Updates', "$($updates.Count) update record(s), none pending")
    }
} else {
    $valRows += ,@('— Unknown', 'Updates', 'Update records not accessible')
}

# Logical networks
if ($logicalNetworks.Count -gt 0) {
    $lnetNames = ($logicalNetworks | ForEach-Object { $_.Name }) -join ', '
    $valRows += ,@("✓ $($logicalNetworks.Count) found", 'Logical Networks', $lnetNames)
} else {
    $valRows += ,@('— None found', 'Logical Networks', 'No logical networks in resource group')
}

# Defender for Cloud
if ($defenderPricings.Count -gt 0) {
    $enabledPlans = @($defenderPricings | Where-Object {
        $_.PSObject.Properties['properties'] -and $_.properties.PSObject.Properties['pricingTier'] -and $_.properties.pricingTier -eq 'Standard'
    })
    if ($enabledPlans.Count -gt 0) {
        $valRows += ,@("✓ $($enabledPlans.Count) plan(s) enabled", 'Defender for Cloud', ($enabledPlans | ForEach-Object { $_.name }) -join ', ')
    } else {
        $valRows += ,@('⚠ Not enabled', 'Defender for Cloud', 'All plans on Free tier — no paid Defender coverage')
    }
} else {
    $valRows += ,@('— Unknown', 'Defender for Cloud', 'Pricing data not accessible')
}

# Monitoring / Insights
if ($monitoringEnabled) {
    $valRows += ,@('✓ Configured', 'Azure Monitor Insights', "Agent: $(if ($monitorAgentExt) { $monitorAgentExt.ProvisioningState } else { 'N/A' }) | DCRs: $($dcrList.Count)")
} else {
    $valRows += ,@('⚠ Not configured', 'Azure Monitor Insights', 'No AzureMonitorWindowsAgent or Data Collection Rules found — logs not forwarded')
}

Add (Format-Table-Md -Headers @('Status','Check','Detail') -Rows $valRows)
Add ""

# ── R3 Configuration Summary ──────────────────────────────────────────────────
Add "---"
Add ""
Add "## Configuration Summary"
Add ""

# ── R3.1 Deployment Scenario & Scale ─────────────────────────────────────────
Add "### Deployment Scenario & Scale"
Add ""
if ($deploySettings) {
    $dc = $deploySettings.DeploymentConfigurationScaleUnit[0]
    $nodeCount = if ($dc.DeploymentDataPhysicalNode) { ($dc.DeploymentDataPhysicalNode | Measure-Object).Count } else { Safe $cluster.ReportedPropertyNode }
    Add "**Deployment Mode:** ``$(Safe $deploySettings.DeploymentMode)``  "
    Add "**Node Count:** $nodeCount  "
    Add "**Storage Configuration Mode:** ``$(Safe $dc.StorageConfigurationMode)``  "
    Add "**Witness Type:** ``$(Safe $dc.ClusterWitnessType)``  "
    if ($dc.ClusterWitnessPath) { Add "**Witness Path:** ``$($dc.ClusterWitnessPath)``  " }
    Add "**Naming Prefix:** ``$(Safe $dc.DeploymentDataNamingPrefix)``  "
} else {
    Add "**Node Count:** $(Safe $cluster.ReportedPropertyNode)  "
    Add ""
    Add "> **Advisory:** Deployment settings not available. Cluster may be in a legacy registration state."
}
Add ""
Add "**Cluster Version:** ``$(Safe $cluster.ReportedPropertyClusterVersion)``  "
Add "**Cluster Type:** ``$(Safe $cluster.ReportedPropertyClusterType)``  "
Add "**Manufacturer:** ``$(Safe $cluster.ReportedPropertyManufacturer)``  "
Add "**IMDS Attestation:** $(StatusBadge (Safe $cluster.ReportedPropertyImdsAttestation))  "
Add "**Diagnostic Level:** ``$(Safe $cluster.ReportedPropertyDiagnosticLevel)``  "
Add "**OEM Activation:** ``$(Safe $cluster.ReportedPropertyOemActivation)``  "
Add ""
if ($cluster.ReportedPropertySupportedCapability) {
    $capList = ($cluster.ReportedPropertySupportedCapability | ForEach-Object { '`' + $_ + '`' }) -join ', '
    Add "**Supported Capabilities:** $capList  "
    Add ""
}
if ($cluster.IsolatedVMAttestationConfigurationAttestationServiceEndpoint) {
    Add "**Attestation Service:** ``$(Safe $cluster.IsolatedVMAttestationConfigurationAttestationServiceEndpoint)``  "
    Add ""
}

# ── R3.2 Node Configuration ───────────────────────────────────────────────────
Add "### Node Configuration"
Add ""
# Merge deployment IP data with reported hardware data
$reportedNodes = if ($cluster.ReportedPropertyNode) { @($cluster.ReportedPropertyNode) } else { @() }
if ($reportedNodes.Count -gt 0) {
    $nodeRows = $reportedNodes | ForEach-Object {
        $nodeName = Safe $_.name
        # Find matching IP from deployment settings
        $ip = 'N/A'
        if ($deploySettings -and $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataPhysicalNode) {
            $match = $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataPhysicalNode |
                Where-Object { $_.Name -ieq $nodeName } | Select-Object -First 1
            if ($match) { $ip = "``$(Safe $match.Ipv4Address)``" }
        }
        $model      = if ($_.PSObject.Properties['model'])            { Safe $_.model }            else { 'N/A' }
        $osVer      = if ($_.PSObject.Properties['osDisplayVersion']) { Safe $_.osDisplayVersion }  else { 'N/A' }
        $serial     = if ($_.PSObject.Properties['serialNumber'])     { "``$(Safe $_.serialNumber)``" } else { 'N/A' }
        $cores      = if ($_.PSObject.Properties['coreCount'])        { Safe $_.coreCount }         else { 'N/A' }
        $mem        = if ($_.PSObject.Properties['memoryInGiB'])      { "$(Safe $_.memoryInGiB) GiB" } else { 'N/A' }
        $oemAct     = if ($_.PSObject.Properties['oemActivation'])    { Safe $_.oemActivation }     else { 'N/A' }
        @($nodeName, $ip, $model, $osVer, $serial, $cores, $mem, $oemAct)
    }
    Add (Format-Table-Md -Headers @('Node','IP Address','Model','OS Version','Serial','Cores','Memory','OEM Act.') -Rows $nodeRows)
} elseif ($deploySettings -and $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataPhysicalNode) {
    $dc = $deploySettings.DeploymentConfigurationScaleUnit[0]
    $nodeRows = $dc.DeploymentDataPhysicalNode | ForEach-Object {
        @((Safe $_.Name), "``$(Safe $_.Ipv4Address)``")
    }
    Add (Format-Table-Md -Headers @('Node Name','IP Address') -Rows $nodeRows)
} else {
    Add "_Node configuration data not available._"
}
Add ""

# Cluster node operational state (from node remoting)
if ($IncludeNodeData -and $nodeData['ClusterNodes'] -and $nodeData['ClusterNodes'].Count -gt 0) {
    Add "**Cluster Node States** *(via PowerShell remoting from ``$firstNode``)*"
    Add ""
    $cnRows = $nodeData['ClusterNodes'] | ForEach-Object {
        @((Safe $_['Name']), (StatusBadge (Safe $_['State'])), (Safe $_['Id']))
    }
    Add (Format-Table-Md -Headers @('Node','State','ID') -Rows $cnRows)
    Add ""
}

# GPU (from node hardware via WinRM)
if ($IncludeNodeData -and $nodeData['GPUs'] -and $nodeData['GPUs'].Count -gt 0) {
    Add "**GPU Hardware** *(via PowerShell remoting from ``$firstNode``)*"
    Add ""
    $gpuRows = $nodeData['GPUs'] | ForEach-Object {
        @((Safe $_['Name']), (Safe $_['DriverVersion']), "$($_['AdapterRAMGB']) GB", (StatusBadge (Safe $_['Status'])))
    }
    Add (Format-Table-Md -Headers @('GPU','Driver Version','VRAM','Status') -Rows $gpuRows)
    Add ""
} elseif ($gpuResources.Count -gt 0) {
    Add "**GPU Driver Instances (ARM)**"
    Add ""
    $gpuRows = $gpuResources | ForEach-Object {
        $gp = if ($_.PSObject.Properties['properties']) { $_.properties } else { $null }
        @((Safe $_.name), (StatusBadge (Safe $gp.provisioningState)))
    }
    Add (Format-Table-Md -Headers @('Name','State') -Rows $gpuRows)
    Add ""
} else {
    Add "> *No GPU hardware detected. GPU support for Azure Local is a preview feature — requires supported GPU hardware and the GPU driver extension.*"
    Add ""
}

# Local Administrators (from node via WinRM)
if ($IncludeNodeData -and $nodeData['LocalAdmins'] -and $nodeData['LocalAdmins'].Count -gt 0) {
    Add "**Local Administrators Group** *(via PowerShell remoting from ``$firstNode``)*"
    Add ""
    $adminRows = $nodeData['LocalAdmins'] | ForEach-Object {
        @((Safe $_['Name']), (Safe $_['ObjectClass']), (Safe $_['PrincipalSource']))
    }
    Add (Format-Table-Md -Headers @('Account','Type','Source') -Rows $adminRows)
    Add ""
} elseif ($IncludeNodeData) {
    Add "_Local administrators group data not available._"
    Add ""
}
Add ""

# ── R3.3 Host Networking, Intents & Overrides ─────────────────────────────────
Add "### Network Configuration"
Add ""

# ── Infrastructure Network ────────────────────────────────────────────────────
Add "#### Infrastructure Network"
Add ""
if ($deploySettings -and $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataInfrastructureNetwork) {
    $dc = $deploySettings.DeploymentConfigurationScaleUnit[0]
    foreach ($infra in $dc.DeploymentDataInfrastructureNetwork) {
        $infraRows = @(
            @('Gateway',     "``$(Safe $infra.Gateway)``"),
            @('Subnet Mask', "``$(Safe $infra.SubnetMask)``"),
            @('DNS Servers', "``$(Safe ($infra.DnsServer -join ', '))``"),
            @('Use DHCP',    (Safe $infra.UseDhcp))
        )
        Add (Format-Table-Md -Headers @('Setting','Value') -Rows $infraRows)
        Add ""
        if ($infra.IPPool) {
            Add "**IP Pool:**"
            Add ""
            $ipPoolRows = $infra.IPPool | ForEach-Object {
                @("``$(Safe $_.StartingAddress)``", "``$(Safe $_.EndingAddress)``")
            }
            Add (Format-Table-Md -Headers @('Start IP','End IP') -Rows $ipPoolRows)
            Add ""
        }
    }
} else {
    Add "_Infrastructure network details not available._"
    Add ""
}

# ── Host Networking Intents ───────────────────────────────────────────────────
Add "#### Host Networking Intents"
Add ""
if ($deploySettings) {
    $dc = $deploySettings.DeploymentConfigurationScaleUnit[0]
    Add "**Storage Auto IP:** ``$(Safe $dc.HostNetworkEnableStorageAutoIP)``  "
    Add "**Storage Switchless:** ``$(Safe $dc.HostNetworkStorageConnectivitySwitchless)``  "
    Add ""
    if ($dc.HostNetworkIntent) {
        foreach ($intent in $dc.HostNetworkIntent) {
            Add "**Intent: ``$(Safe $intent.Name)``**"
            Add ""
            $intentRows = @(
                @('Traffic Type',    (Safe ($intent.TrafficType -join ', '))),
                @('Adapters',        (Safe ($intent.Adapter -join ', '))),
                @('Jumbo Packet',    (Safe $intent.AdapterPropertyOverrideJumboPacket)),
                @('RDMA Enabled',    (Safe $intent.AdapterPropertyOverrideNetworkDirect)),
                @('RDMA Technology', (Safe $intent.AdapterPropertyOverrideNetworkDirectTechnology))
            )
            Add (Format-Table-Md -Headers @('Property','Value') -Rows $intentRows)
            Add ""
        }
        if ($dc.HostNetworkStorageNetwork) {
            Add "**Storage Networks:**"
            Add ""
            $storNetRows = $dc.HostNetworkStorageNetwork | ForEach-Object {
                @("``$(Safe $_.Name)``", "``$(Safe $_.NetworkAdapterName)``", "``$(Safe $_.VlanId)``")
            }
            Add (Format-Table-Md -Headers @('Name','Adapter','VLAN') -Rows $storNetRows)
            Add ""
        }
    } else {
        Add "_No network intents found in deployment settings._"
        Add ""
    }
} else {
    Add "_Host networking details not available._"
    Add ""
}

# ── Node NICs ─────────────────────────────────────────────────────────────────
Add "#### Node NICs"
Add ""
if ($IncludeNodeData -and $nodeData['NetAdapters'] -and $nodeData['NetAdapters'].Count -gt 0) {
    Add "> *Via PowerShell remoting from ``$firstNode``.*"
    Add ""
    $nicRows = $nodeData['NetAdapters'] | ForEach-Object {
        @(
            (Safe $_['Name']),
            (Safe $_['InterfaceDescription']),
            (Safe $_['LinkSpeed']),
            "``$(Safe $_['MacAddress'])``"
        )
    }
    Add (Format-Table-Md -Headers @('Adapter','Description','Speed','MAC Address') -Rows $nicRows)
} else {
    Add "_Per-node NIC detail requires ``-IncludeNodeData``. Showing ARM-sourced node list only._"
    Add ""
    if ($deploySettings -and $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataPhysicalNode) {
        $dc = $deploySettings.DeploymentConfigurationScaleUnit[0]
        $nodeRows = $dc.DeploymentDataPhysicalNode | ForEach-Object {
            @((Safe $_.Name), "``$(Safe $_.Ipv4Address)``")
        }
        Add (Format-Table-Md -Headers @('Node','Management IP') -Rows $nodeRows)
    }
}
Add ""

# ── Logical Networks ──────────────────────────────────────────────────────────
Add "#### Logical Networks"
Add ""
if ($logicalNetworks.Count -gt 0) {
    foreach ($net in $logicalNetworks) {
        Add "**``$($net.Name)``**"
        Add ""
        $netProps = if ($net.PSObject.Properties['Properties']) { $net.Properties } else { $null }
        if (-not $netProps) { continue }
        Add "**VM Switch:** ``$(Safe $netProps.vmSwitchName)``  "
        Add "**Provisioning State:** $(StatusBadge (Safe $netProps.provisioningState))  "
        Add ""
        if ($netProps.subnets) {
            $subnetRows = $netProps.subnets | ForEach-Object {
                @(
                    (Safe $_.name),
                    "``$(Safe $_.properties.addressPrefix)``",
                    (Safe $_.properties.ipAllocationMethod),
                    (Safe $_.properties.vlan)
                )
            }
            Add (Format-Table-Md -Headers @('Subnet','CIDR','Allocation','VLAN') -Rows $subnetRows)
            Add ""
        }
    }
} else {
    Add "_No logical networks found._"
    Add ""
}

# ── Network Security Groups ───────────────────────────────────────────────────
Add "#### Network Security Groups"
Add ""
if ($nsgList.Count -gt 0) {
    foreach ($nsg in $nsgList) {
        $nsgName  = if ($nsg.PSObject.Properties['name'])       { $nsg.name }       else { 'Unknown' }
        $nsgProps = if ($nsg.PSObject.Properties['properties']) { $nsg.properties } else { $null }
        $state    = if ($nsgProps -and $nsgProps.PSObject.Properties['provisioningState']) { $nsgProps.provisioningState } else { 'N/A' }
        $subnets  = @(if ($nsgProps -and $nsgProps.PSObject.Properties['subnets']           -and $nsgProps.subnets)           { $nsgProps.subnets }           else { })
        $nics     = @(if ($nsgProps -and $nsgProps.PSObject.Properties['networkInterfaces'] -and $nsgProps.networkInterfaces) { $nsgProps.networkInterfaces } else { })
        $rules    = @(if ($nsg.PSObject.Properties['_securityRules'] -and $nsg._securityRules) { $nsg._securityRules } else { })

        Add "**``$nsgName``** — $(StatusBadge $state)"
        Add ""

        # Summary table: attachments
        $lnNames  = if ($subnets.Count -gt 0) { ($subnets | ForEach-Object { $_.id -replace '.*/' }) -join ', ' } else { '_None_' }
        $nicNames = if ($nics.Count    -gt 0) { ($nics    | ForEach-Object { $_.id -replace '.*/' }) -join ', ' } else { '_None_' }
        Add (Format-Table-Md -Headers @('Property','Value') -Rows @(
            @('Provisioning State', (StatusBadge $state)),
            @('Logical Networks',   $lnNames),
            @('Network Interfaces', $nicNames),
            @('Security Rules',     $rules.Count.ToString())
        ))
        Add ""

        # Rules table — split inbound / outbound
        if ($rules.Count -gt 0) {
            foreach ($dir in @('Inbound','Outbound')) {
                $dirRules = @($rules | Where-Object { $_.properties.direction -eq $dir })
                if ($dirRules.Count -gt 0) {
                    Add "**$dir Rules**"
                    Add ""
                    $ruleRows = @($dirRules | Sort-Object { $_.properties.priority } | ForEach-Object {
                        $rp  = $_.properties
                        $src = if (@($rp.sourceAddressPrefixes).Count -gt 0) { ($rp.sourceAddressPrefixes | Where-Object { $_ }) -join ',' } else { Safe $rp.sourceAddressPrefix }
                        $dst = if (@($rp.destinationPortRanges).Count -gt 0) { ($rp.destinationPortRanges | Where-Object { $_ }) -join ',' } else { Safe $rp.destinationPortRange }
                        $proto = if ($rp.protocol -eq '*') { 'Any' } else { Safe $rp.protocol }
                        @(
                            (Safe $_.name),
                            (Safe $rp.priority),
                            (Safe $rp.access),
                            $proto,
                            $src,
                            $dst
                        )
                    })
                    Add (Format-Table-Md -Headers @('Rule','Priority','Access','Protocol','Source','Dst Port') -Rows $ruleRows)
                    Add ""
                }
            }
        } else {
            Add "_No security rules defined._"
            Add ""
        }
    }
} else {
    Add "_No Network Security Groups found in this resource group._"
    Add ""
}

# ── R3.5 Active Directory Configuration ──────────────────────────────────────
Add "### Active Directory Configuration"
Add ""
if ($deploySettings -and $deploySettings.DeploymentConfigurationScaleUnit[0].DeploymentDataAdouPath) {
    $dc = $deploySettings.DeploymentConfigurationScaleUnit[0]
    Add "**Domain FQDN:** ``$($dc.DeploymentDataDomainFqdn)``  "
    Add "**OU Path:** ``$($dc.DeploymentDataAdouPath)``  "
    Add "**Secrets Location:** ``$(Safe $dc.DeploymentDataSecretsLocation)``  "
} else {
    Add "**AAD Tenant ID:** ``$(Safe $cluster.AadTenantId)``  "
    Add "**AAD Client ID:** ``$(Safe $cluster.AadClientId)``  "
    Add "**AAD App Object ID:** ``$(Safe $cluster.AadApplicationObjectId)``  "
    Add "**AAD SP Object ID:** ``$(Safe $cluster.AadServicePrincipalObjectId)``  "
    Add ""
    Add "_Active Directory deployment data not available (ARM-only identity details shown)._"
}
Add ""

# ── R3.7 Security Configuration ───────────────────────────────────────────────
Add "### Security Configuration"
Add ""
if ($deploySettings) {
    $dc = $deploySettings.DeploymentConfigurationScaleUnit[0]
    $secDeployRows = @(
        @('BitLocker Boot Volume',           (Safe $dc.SecuritySettingBitlockerBootVolume)),
        @('BitLocker Data Volume',           (Safe $dc.SecuritySettingBitlockerDataVolume)),
        @('Credential Guard',                (Safe $dc.SecuritySettingCredentialGuardEnforced)),
        @('Drift Control',                   (Safe $dc.SecuritySettingDriftControlEnforced)),
        @('DRTM Protection',                 (Safe $dc.SecuritySettingDrtmProtection)),
        @('HVCI Protection',                 (Safe $dc.SecuritySettingHvciProtection)),
        @('Side Channel Mitigation',         (Safe $dc.SecuritySettingSideChannelMitigationEnforced)),
        @('SMB Cluster Encryption',          (Safe $dc.SecuritySettingSmbClusterEncryption)),
        @('SMB Signing',                     (Safe $dc.SecuritySettingSmbSigningEnforced)),
        @('WDAC',                            (Safe $dc.SecuritySettingWdacEnforced))
    )
    Add (Format-Table-Md -Headers @('Security Setting','Value') -Rows $secDeployRows)
    Add ""
} elseif ($securitySettings) {
    $secRows = $securitySettings.PSObject.Properties | ForEach-Object { @($_.Name, (Safe $_.Value)) }
    if ($secRows) { Add (Format-Table-Md -Headers @('Setting','Value') -Rows $secRows) }
    Add ""
} else {
    Add "_Security configuration data not available._"
    Add ""
}

# ── R3.8 Microsoft Defender for Cloud ────────────────────────────────────────
Add "### Microsoft Defender for Cloud"
Add ""
if ($defenderPricings.Count -gt 0) {
    $defPlanNames = @{
        'HybridCompute'           = 'Defender for Servers (Arc)'
        'Containers'              = 'Defender for Containers'
        'VirtualMachines'         = 'Defender for Servers (VMs)'
        'SqlServerVirtualMachines'= 'Defender for SQL on Machines'
        'KubernetesService'       = 'Defender for Kubernetes'
        'Dns'                     = 'Defender for DNS'
        'StorageAccounts'         = 'Defender for Storage'
    }
    $defRows = $defenderPricings | ForEach-Object {
        $planName    = if ($defPlanNames.ContainsKey($_.name)) { $defPlanNames[$_.name] } else { $_.name }
        $tier        = if ($_.PSObject.Properties['properties'] -and $_.properties.PSObject.Properties['pricingTier']) { $_.properties.pricingTier } else { 'N/A' }
        $subPlan     = if ($_.PSObject.Properties['properties'] -and $_.properties.PSObject.Properties['subPlan']) { Safe $_.properties.subPlan } else { '' }
        $tierDisplay = if ($tier -eq 'Standard') { "✓ Enabled$(if ($subPlan) { " ($subPlan)" })" } else { "— Free / Not enabled" }
        @($planName, $tierDisplay)
    }
    Add (Format-Table-Md -Headers @('Plan','Status') -Rows $defRows)
} else {
    Add "_Defender for Cloud pricing data not accessible._"
}
Add ""

# ── R3.9 Billing & Licensing ──────────────────────────────────────────────────
Add "### Billing & Licensing"
Add ""
$billingRows = @(
    @('Billing Model',                    (Safe $cluster.BillingModel)),
    @('Trial Days Remaining',             (Safe $cluster.TrialDaysRemaining)),
    @('Last Billing Timestamp',           (Safe $cluster.LastBillingTimestamp)),
    @('Software Assurance Status',        (StatusBadge (Safe $cluster.SoftwareAssurancePropertySoftwareAssuranceStatus))),
    @('Software Assurance Intent',        (Safe $cluster.SoftwareAssurancePropertySoftwareAssuranceIntent)),
    @('Windows Server Subscription',      (StatusBadge (Safe $cluster.DesiredPropertyWindowsServerSubscription)))
)
Add (Format-Table-Md -Headers @('Property','Value') -Rows $billingRows)
Add ""

# ── R3.10 Monitoring & Insights ───────────────────────────────────────────────
Add "### Monitoring & Insights"
Add ""
if ($monitoringEnabled) {
    $monRows = @()
    $agentState = if ($monitorAgentExt) { StatusBadge $monitorAgentExt.ProvisioningState } else { '— Not found' }
    $monRows += ,@('AzureMonitorWindowsAgent', $agentState, (if ($monitorAgentExt) { (Safe $monitorAgentExt.ParameterTypeHandlerVersion) } else { 'N/A' }))
    if ($dcrList.Count -gt 0) {
        foreach ($dcr in $dcrList) {
            $dcrName   = if ($dcr.PSObject.Properties['name'])  { $dcr.name }  else { 'Unknown' }
            $dcrProp   = if ($dcr.PSObject.Properties['properties']) { $dcr.properties } else { $null }
            $lawId     = if ($dcrProp -and $dcrProp.PSObject.Properties['destinations']) {
                            $la = $dcrProp.destinations.PSObject.Properties['logAnalytics']
                            if ($la) { ($la.Value | Select-Object -First 1).workspaceResourceId } else { 'N/A' }
                         } else { 'N/A' }
            $monRows += ,@($dcrName, '✓ Data Collection Rule', $lawId)
        }
    }
    Add (Format-Table-Md -Headers @('Name','Status','Details') -Rows $monRows)
} else {
    Add "> **⚠ Advisory:** Azure Monitor agent not detected and no Data Collection Rules found in this resource group. Cluster Insights (log forwarding to Log Analytics) appears to be **not configured**."
}
Add ""

# ── R5 Workloads & Platform Configuration ────────────────────────────────────
Add "---"
Add ""
Add "## Workloads & Platform Configuration"
Add ""

# ── R5.1 Azure Arc & Extensions ───────────────────────────────────────────────
Add "### Azure Arc & Extensions"
Add ""
if ($arcSettings) {
    $arcRows = @(
        @('Arc Instance Resource Group', (Safe $arcSettings.ArcInstanceResourceGroup)),
        @('Aggregate State',             (StatusBadge (Safe $arcSettings.AggregateState))),
        @('Arc Application Object ID',   "``$(Safe $arcSettings.ArcApplicationObjectId)``"),
        @('Arc SP Object ID',            "``$(Safe $arcSettings.ArcServicePrincipalObjectId)``")
    )
    Add (Format-Table-Md -Headers @('Property','Value') -Rows $arcRows)
    Add ""
}
if ($extensions.Count -gt 0) {
    $extRows = $extensions | ForEach-Object {
        @(
            (Safe $_.Name),
            "``$(Safe $_.ParameterType)``",
            (Safe $_.ParameterTypeHandlerVersion),
            (StatusBadge (Safe $_.ProvisioningState)),
            (Safe $_.ManagedBy)
        )
    }
    Add (Format-Table-Md -Headers @('Extension','Type','Version','State','Managed By') -Rows $extRows)
} else {
    Add "_No Arc extensions found or accessible._"
}
Add ""

# ── R5.2 Virtual Machines & Images ────────────────────────────────────────────
Add "### Virtual Machines & Images"
Add ""
if ($vmInstances.Count -gt 0) {
    $vmRows = $vmInstances | ForEach-Object {
        $state = if ($_.PSObject.Properties['properties'] -and $_.properties.PSObject.Properties['provisioningState']) { Safe $_.properties.provisioningState } else { 'N/A' }
        $sub   = if ($_._subscription -ne $subId) { $_._subscription } else { '(current)' }
        @((Safe $_._machineName), (Safe $_._resourceGroup), $sub, (Safe $_._location), (StatusBadge $state))
    }
    Add (Format-Table-Md -Headers @('VM Name','Resource Group','Subscription','Location','State') -Rows $vmRows)
    Add ""
} else {
    Add "_No virtual machine instances found._"
    Add ""
}
if ($galleryImages.Count -gt 0) {
    Add "**Available Images:**"
    Add ""
    $imgRows = $galleryImages | ForEach-Object {
        $p = if ($_.PSObject.Properties['Properties']) { $_.Properties } else { $null }
        @(
            (Safe $_.Name),
            (Safe $_.ResourceType.Split('/')[-1]),
            (Safe $p.osType),
            (Safe $p.hyperVGeneration),
            (StatusBadge (Safe $p.provisioningState))
        )
    }
    Add (Format-Table-Md -Headers @('Name','Source','OS','Hyper-V Gen','State') -Rows $imgRows)
    Add ""
}

# ── R5.3 Kubernetes Clusters ──────────────────────────────────────────────────
Add "### Kubernetes Clusters"
Add ""
if ($k8sClusters.Count -gt 0) {
    $k8sRows = $k8sClusters | ForEach-Object {
        $kp    = if ($_.PSObject.Properties['Properties']) { $_.Properties } else { $null }
        $state = if ($kp -and $kp.PSObject.Properties['provisioningState']) { Safe $kp.provisioningState }
                 elseif ($kp -and $kp.PSObject.Properties['kubernetesVersion']) { 'Succeeded' }
                 else { 'N/A' }
        $k8sVer = if ($kp -and $kp.PSObject.Properties['kubernetesVersion']) { Safe $kp.kubernetesVersion } else { 'N/A' }
        $kind   = $_.ResourceType.Split('/')[-1]
        @((Safe $_.Name), $kind, $k8sVer, (Safe $_.ResourceGroupName), (StatusBadge $state))
    }
    Add (Format-Table-Md -Headers @('Name','Kind','K8s Version','Resource Group','State') -Rows $k8sRows)
} else {
    Add "_No Kubernetes clusters found in this resource group._"
}
Add ""

# ── R5.4 Updates ──────────────────────────────────────────────────────────────
Add "### Updates"
Add ""
if ($updates.Count -gt 0) {
    $updateRows = $updates | Sort-Object { [Version]($_.Version -replace '^[^0-9]*','') } -Descending | Select-Object -First 20 | ForEach-Object {
        @(
            (Safe $_.DisplayName),
            "``$(Safe $_.Version)``",
            (StatusBadge (Safe $_.State)),
            (Safe $_.AvailabilityType),
            (Safe $_.ReleaseLink)
        )
    }
    Add (Format-Table-Md -Headers @('Name','Version','State','Availability','Release Notes') -Rows $updateRows)
} else {
    Add "_No update records found or update service not accessible._"
}
Add ""

# ── R5.5 Storage Configuration ────────────────────────────────────────────────
Add "### Storage Configuration"
Add ""
if ($IncludeNodeData -and $nodeData['StoragePools'] -and $nodeData['StoragePools'].Count -gt 0) {
    Add "> *Via PowerShell remoting from ``$firstNode``.*"
    Add ""
    $poolRows = $nodeData['StoragePools'] | ForEach-Object {
        @(
            (Safe $_['FriendlyName']),
            (StatusBadge (Safe $_['OperationalStatus'])),
            "$($_.TotalSizeGB) GB",
            "$($_.AllocatedSizeGB) GB"
        )
    }
    Add (Format-Table-Md -Headers @('Pool Name','Status','Total','Allocated') -Rows $poolRows)
    Add ""
    if ($nodeData['Volumes'] -and $nodeData['Volumes'].Count -gt 0) {
        Add "**Volumes:**"
        Add ""
        $volRows = $nodeData['Volumes'] | ForEach-Object {
            @(
                (Safe $_['FriendlyName']),
                (Safe $_['FileSystem']),
                "$($_['SizeGB']) GB",
                "$($_['SizeRemainingGB']) GB",
                (StatusBadge (Safe $_['HealthStatus']))
            )
        }
        Add (Format-Table-Md -Headers @('Volume','File System','Size','Free','Health') -Rows $volRows)
        Add ""
    }
    if ($nodeData['PhysicalDisks'] -and $nodeData['PhysicalDisks'].Count -gt 0) {
        Add "**Physical Disks** *(sampled from first node):*"
        Add ""
        $diskRows = $nodeData['PhysicalDisks'] | ForEach-Object {
            @(
                (Safe $_['FriendlyName']),
                (Safe $_['MediaType']),
                (Safe $_['BusType']),
                "$($_['SizeGB']) GB",
                (StatusBadge (Safe $_['OperationalStatus']))
            )
        }
        Add (Format-Table-Md -Headers @('Model','Media','Bus','Size','Status') -Rows $diskRows)
        Add ""
    }
} else {
    Add "_Storage pool data requires ``-IncludeNodeData``. Storage configuration mode from deployment settings:_"
    Add ""
    if ($deploySettings) {
        $dc = $deploySettings.DeploymentConfigurationScaleUnit[0]
        Add "**Storage Configuration Mode:** ``$(Safe $dc.StorageConfigurationMode)``  "
    }
    Add ""
}

# ── Footer ────────────────────────────────────────────────────────────────────
Add "---"
Add ""
Add "*Generated by Get-AzLocalDoc for Azure Local ([Get-AzLocalDoc](https://github.com/chkja/Get-AzLocalDoc)) — $generatedAt*"
Add ""

#endregion

#region ── Write Output ─────────────────────────────────────────────────────────

if (-not $OutputPath) {
    $safeName  = $ClusterName -replace '[^a-zA-Z0-9\-]', '_'
    $dateStamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $OutputPath = ".\AzureLocal-${safeName}-${dateStamp}.md"
}

$markdownContent = $sb.ToString()
$markdownContent | Set-Content -Path $OutputPath -Encoding UTF8

Write-Host ""
Write-Host "✅ Documentation written to: $OutputPath" -ForegroundColor Green
Write-Host "   $(($markdownContent -split "`n").Count) lines | $([math]::Round($markdownContent.Length / 1KB, 1)) KB"

#endregion
