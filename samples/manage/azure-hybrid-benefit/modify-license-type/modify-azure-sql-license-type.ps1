<#
.SYNOPSIS
    Updates the license type for Azure SQL resources (SQL DBs, Elastic Pools, Managed Instances, Instance Pools, SQL VMs)
    to a specified model ("LicenseIncluded" or "BasePrice"). Optionally starts resources if needed.

.DESCRIPTION
    The script updates Azure SQL License types across subscriptions by modifying the license settings for a variety of SQL resources. It supports processing resources in one of the following ways:

Single Subscription:
Run against a specified subscription ID.
CSV List of Subscriptions:
Process multiple subscriptions provided in a CSV file.
All Accessible Subscriptions:
Automatically detect and update all subscriptions that you have access to.

The script processes several types of Azure SQL resources including:

SQL Virtual Machines (SQL VMs)
SQL Managed Instances
SQL Databases
Elastic Pools
SQL Instance Pools
DataFactory SSIS Integration Runtimes
This automation helps ensure that your licensing configuration is consistent across your environment without manual intervention.

.VERSION
    1.0.0 - Initial version.

.PARAMETER SubId
    A single subscription ID or a CSV file name containing a list of subscriptions.

.PARAMETER ResourceGroup
    Optional. Limit the scope to a specific resource group.

.PARAMETER LicenseType
    Optional. License type to set. Allowed values: "LicenseIncluded" (default) or "BasePrice".

.PARAMETER ExclusionTags
    Optional. If specified, excludes the resources that have this tag assigned.

.PARAMETER TenantId
    Optional. If specified, this tenant id to log in both PoaerShell and CLI. Otyherwise, the current logoin context is used.

.PARAMETER ReportOnly
    Optional. If true, generates a csv file with the list of resources that are to be modified, but doesn't make the actual change.

.PARAMETER UseManagedIdentity
    Optional. If true, logs in both PoaerShell and CLI using managed identity. Required to run the script as a runbook.

#>

param (
    [Parameter(Mandatory = $false)]
    [string] $SubId="$null",
    
    [Parameter(Mandatory = $false)]
    [string] $ResourceGroup=$null,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("LicenseIncluded", "BasePrice", IgnoreCase = $false)]
    [string] $LicenseType = "LicenseIncluded",
    
    [Parameter (Mandatory= $false)]
    [object] $ExclusionTags,

    [Parameter (Mandatory= $false)]
    [string] $TenantId,

    [Parameter (Mandatory= $false)]
    [switch] $ReportOnly,

    [Parameter (Mandatory= $false)]
    [switch] $UseManagedIdentity
)

# Suppress unnecessary logging output
$VerbosePreference      = "SilentlyContinue"
$DebugPreference        = "SilentlyContinue"
$ProgressPreference     = "SilentlyContinue"
$InformationPreference  = "SilentlyContinue"
$WarningPreference      = "SilentlyContinue"

function Connect-Azure {
    [CmdletBinding()]
    param(
         [Parameter (Mandatory= $true)]
         [string] $TenantId,

         [Parameter (Mandatory= $false)]
         [switch]$UseManagedIdentity
    )

    # 1) Detect environment
    $envType = "Local"
    if ($env:AZUREPS_HOST_ENVIRONMENT -and $env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*') {
        $envType = "CloudShell"
    }
    elseif (($env:AZUREPS_HOST_ENVIRONMENT -and $env:AZUREPS_HOST_ENVIRONMENT -like 'AzureAutomation*') -or $PSPrivateMetadata.JobId) {
        $envType = "AzureAutomation"
        $UseManagedIdentity=$true
    }
    Write-Verbose "Environment detected: $envType"

    # 2) Ensure Az.PowerShell context
    Write-Output "Not connected to Azure PowerShell. Running Connect-AzAccount..."
    if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
        $ctx = Connect-AzAccount -Tenant $TenantId -Identity -ErrorAction Stop | Out-Null
    }
    else {
        $ctx = Connect-AzAccount -Tenant $TenantId -ErrorAction Stop | Out-Null
    }
    Write-Output "Connected to Azure PowerShell as: $($ctx.Account)"

    # 3) Sync Azure CLI if available
    if (Get-Command az -ErrorAction SilentlyContinue) {
        Write-Output "Running az login..."
        if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
            az login --tenant $TenantId --identity | Out-Null
        }
        else {
            az login --tenant $TenantId | Out-Null
        }
        $acct = az account show --output json | ConvertFrom-Json
    }
    Write-Output "Azure CLI logged in as: $($acct.user.name)"        

}


# Initialize final status and report counters.
$finalStatus = @()

# Convert to hashtable explicitly
$tagTable = @{}
if($null -ne $ExclusionTags){
    if($ExclusionTags.GetType().Name -eq "Hashtable"){
        $tagTable = $ExclusionTags    
    }else{
        ($ExclusionTags | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $tagTable[$_.Name] = $_.Value
        }
    }
}

if (-not $TenantId) {
    $TenantId =  (Get-AzContext).Tenant.Id
    Write-Output "No TenantId provided. Using current context TenantId: $TenantId"
} else {
    Write-Output "Using provided TenantId: $TenantId"
}
# Ensure connection with both PowerShell and CLI.
if ($UseManagedIdentity) {
    Connect-Azure ($TenantId, $UseManagedIdentity)
}else{
    Connect-Azure ($TenantId)
}

# Ensure the required modules are imported

# Ensure NuGet provider is available
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -Force
}

# Check if Az module is installed
$installedModule = Get-InstalledModule -Name Az -ErrorAction SilentlyContinue

if (-not $installedModule) {
    Write-Host "Az module not found. Installing latest version..."
    Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
} else {
    # Get the latest version available in the PSGallery
    $latestVersion = (Find-Module -Name Az -Repository PSGallery).Version
    if ($installedModule.Version -lt $latestVersion) {
        Write-Host "Az module is outdated. Updating to latest version..."
        Update-Module -Name Az -Force
    } else {
        Write-Host "Az module is already up to date. No action needed."
    }
}

# Import Az.Accounts with minimum version requirement
try {
    Import-Module Az.Accounts -MinimumVersion 4.2.0 -Force
    Write-Host "Az.Accounts module imported successfully."
} catch {
    Write-Error "Failed to import Az.Accounts: $_"
    return
}

# Ensure Az.DataFactory is available and import it
try {
    if (-not (Get-Module -ListAvailable -Name Az.DataFactory)) {
        Write-Host "Az.DataFactory module not found. Installing..."
        Install-Module -Name Az.DataFactory -Scope CurrentUser -Force
    } else {
        Write-Host "Az.DataFactory module is already installed."
    }
    Import-Module Az.DataFactory -Force
} catch {
    Write-Error "Can't import module Az.DataFactory: $_"
}

# Map License Types for SQL VMs: LicenseIncluded -> PAYG, BasePrice -> AHUB.
$SqlVmLicenseType = if ($LicenseType -eq "LicenseIncluded") { "PAYG" } else { "AHUB" }

# Modified resources array
$modifiedResources = @()

# Determine the subscriptions to process: CSV file, single subscription, or all accessible subscriptions.
if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId
}elseif($SubId -ne "") {
    Write-Output "Passed Subscription $($SubId)"
    $subscriptions = Get-AzSubscription -SubscriptionId $SubId
}else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.TenantId -eq $tenantId }
}

# Build resource group filter if specified.
$rgFilter = if ($ResourceGroup) { "resourceGroup=='$ResourceGroup'" } else { "" }
$scriptStartTime = Get-Date
Write-Output "Our adventure begins at: $scriptStartTime`n"
$tagsFilter = $null
if($tagTable.Keys.Count -gt 0) {
    $tagsFilter += " && "
    $tagcount = $tagTable.Keys.Count
    foreach ($tag in $tagTable.Keys) {
        $tagcount --
        $tagsFilter += " tags.$($tag) != '$($tagTable[$tag])' "
        if($tagcount -gt 0) {
            $tagsFilter += " && "
        }
    }
}

# Process each subscription.
foreach ($sub in $subscriptions) {
    try {
        Write-Output "===== Entering Subscription: $($sub.name) ====="
        Write-Output "Switching context to subscription: $($sub.name)"
        <#if($SqlVmLicenseType -eq "LicenseIncluded") {
            Write-Output "SQL VM License Type: PAYG"
            $ArcSQLServerExtensionDeployment = az tag list --resource-id "/subscriptions/$sub.id" --query "properties.tags.ArcSQLServerExtensionDeployment" -o json | ConvertFrom-Json
            if ($ArcSQLServerExtensionDeployment -ne "LicenseIncluded") {
                Write-Output "SQL VM License Type: PAYG"
                az tag update --resource-id /"/subscriptions/$sub.id" --operation merge --tags ArcSQLServerExtensionDeployment=PAYG | Out-Null
            }
        } else {
            Write-Output "SQL VM License Type: AHUB"
        }#>

        Write-Output "License Type: $LicenseType"
        az account set --subscription $sub.id

        # --- Section: Update SQL Virtual Machines ---
        try {
            Write-Output "Seeking SQL Virtual Machines that require a license update to $SqlVmLicenseType..."
            $sqlVmQuery = if ($rgFilter) {
                "[?sqlServerLicenseType!='${SqlVmLicenseType}' && sqlServerLicenseType!= 'DR' && $rgFilter $tagsFilter].{name:name, resourceGroup:resourceGroup, sqlServerLicenseType:sqlServerLicenseType, type:type, id:id, Location:location}"
            } else {
                "[?sqlServerLicenseType!='${SqlVmLicenseType}' && sqlServerLicenseType!= 'DR' $tagsFilter].{name:name, resourceGroup:resourceGroup, sqlServerLicenseType:sqlServerLicenseType, type:type, id:id, Location:location}"
            }


            Write-Output "Seeking SQL Virtual Machines with filter $sqlVmQuery..."
            $sqlVMs = az sql vm list --query $sqlVmQuery -o json | ConvertFrom-Json
            $sqlVmsToUpdate = [System.Collections.ArrayList]::new()
            if($sqlVMs.Count -eq 0) {
                Write-Output "No SQL VMs found that require a license update."
            } else {
                Write-Output "Found $($sqlVMs.Count) SQL VMs that require a license update."
            }
            foreach ($sqlvm in $sqlVMs) {

                if($null -ne (az vm list --query "[?name=='$sqlvm.name' && resourceGroup=='$sqlvm.resourceGroup' $tagsFilter]"))
                {
                    $vmStatus = az vm get-instance-view --resource-group $sqlvm.resourceGroup --name $sqlvm.name --query "{Name:name, ResourceGroup:resourceGroup, PowerState:instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]}" -o json | ConvertFrom-Json
                    if ($vmStatus.PowerState -eq "VM running") {
                        
                        # Collect data before modification
                        $modifiedResources += [PSCustomObject]@{
                            TenantID            = $TenantId
                            SubID               = ($sqlvm.id -split '/')[2]
                            ResourceName        = $sqlvm.name
                            ResourceType        = "Microsoft.SqlVirtualMachine/sqlVirtualMachines"
                            Status              = $vmStatus.PowerState
                            OriginalLicenseType = $sqlvm.sqlServerLicenseType
                            ResourceGroup       = $sqlvm.resourceGroup
                            Location            = $sqlvm.Location
                            # Cores             <To be added>
                        }

        
                        if (-not $ReportOnly) {
                            Write-Output "Updating SQL VM '$($sqlvm.name)' in RG '$($sqlvm.resourceGroup)' to license type '$SqlVmLicenseType'..."
                            $result = az sql vm update -n $sqlvm.name -g $sqlvm.resourceGroup --license-type $SqlVmLicenseType -o json | ConvertFrom-Json
                            $finalStatus += $result
                        }
                    }
                }
                else {
                    Write-Output "SQL VM '$($sqlvm.name)' in RG '$($sqlvm.resourceGroup)' Skipping because of tags ($tags)..."
                }
            }
            if($sqlVmsToUpdate.Count -eq 0) {
                Write-Output "No SQL VMs found to start that require a license update."
            } else {
                Write-Output "Found $($sqlVmsToUpdate.Count) to Start SQL VMs that require a license update."
            }
        }
        catch {
            Write-Error "An error occurred while updating SQL VMs: $_"
        }

        # --- Section: Update SQL Managed Instances (Stopped then Ready) "hybridSecondaryUsage": "Passive"---
        $sqlMIsToUpdate = [System.Collections.ArrayList]::new()
        try {
            
            Write-Output "Processing SQL Managed Instances that are running to $LicenseType..."
            $miRunningQuery = "[?licenseType!='${LicenseType}' && hybridSecondaryUsage!='Passive' && state=='Ready'"

            if ($rgFilter) {
                $miRunningQuery += " && $rgFilter"
            }

            if ($tagsFilter) {
                $miRunningQuery += " $tagsFilter"
            }

            $miRunningQuery += "].{name:name, state:state, resourceGroup:resourceGroup, licenseType:licenseType, location:location, id:id, ResourceType:type}"

            Write-Output "Processing SQL Managed Instances that are running with filter $miRunningQuery..."
            $runningMIs = az sql mi list --query $miRunningQuery -o json | ConvertFrom-Json
            if($runningMIs.Count -eq 0) {
                Write-Output "No SQL Managed Instances found that require a license update."
            } else {
                Write-Output "Found $($runningMIs.Count) SQL Managed Instances that require a license update."
            }
            foreach ($mi in $runningMIs) {
                        
                # Collect data before modification
                $modifiedResources += [PSCustomObject]@{
                    TenantID            = $TenantId
                    SubID               = ($mi.id -split '/')[2]
                    ResourceName        = $mi.name
                    ResourceType        = $mi.ResourceType
                    Status              = $mi.State
                    OriginalLicenseType = $mi.licenseType
                    ResourceGroup       = $mi.resourceGroup
                    Location            = $mi.location
                }
                
                if (-not $ReportOnly) {
                    Write-Output "Updating SQL Managed Instance '$($mi.name)' in RG '$($mi.resourceGroup)' to license type '$LicenseType'..."
                    $result = az sql mi update --name $mi.name --resource-group $mi.resourceGroup --license-type $LicenseType -o json | ConvertFrom-Json
                    $finalStatus += $result
                }
            }
        }
        catch {
            Write-Error "An error occurred while updating SQL Managed Instances: $_"
        }

        # --- Section: Update SQL Databases and Elastic Pools ---
        try {
            Write-Output "Querying SQL Servers within this subscription..."
            $serverQuery = if ($rgFilter) { "[?$rgFilter]" } else { "[]" }
            $servers = az sql server list --query $serverQuery -o json | ConvertFrom-Json

            foreach ($server in $servers) {
                # Update SQL Databases
                Write-Output "Scanning SQL Databases on server '$($server.name)'..."
                $dbs = az sql db list --resource-group $server.resourceGroup --server $server.name --query "[?licenseType!='$($LicenseType)' && licenseType!=null $tagsFilter].{name:name, licenseType:licenseType, location:location, resourceGroup:resourceGroup, id:id, ResourceType:type, State:status}" -o json | ConvertFrom-Json
                if( $dbs.Count -eq 0) {
                    Write-Output "No SQL Databases found on Server $($server.name) that require a license update."
                } else {
                    Write-Output "Found $($dbs.Count) SQL Databases on Server $($server.name) that require a license update."
                }
                foreach ($db in $dbs) {
                    
                    # Collect data before modification
                    $modifiedResources += [PSCustomObject]@{
                        TenantID            = $TenantId
                        SubID               = ($db.id -split '/')[2]
                        ResourceName        = $db.name
                        ResourceType        = $db.ResourceType
                        Status              = $db.State
                        OriginalLicenseType = $db.licenseType
                        ResourceGroup       = $db.resourceGroup
                        Location            = $db.location
                    }
                    
                    if (-not $ReportOnly) {
                        Write-Output "Updating SQL Database '$($db.name)' on server '$($server.name)' to license type '$LicenseType'..."
                        $result = az sql db update --name $db.name --server $server.name --resource-group $server.resourceGroup --set licenseType=$LicenseType -o json | ConvertFrom-Json
                        $finalStatus += $result
                    }
                }

                # Update Elastic Pools
                try {
                    Write-Output "Scanning Elastic Pools on server '$($server.name)'..."
                    $elasticPools = az sql elastic-pool list --resource-group $server.resourceGroup --server $server.name --query "[?licenseType!='$($LicenseType)' && licenseType!=null $tagsFilter].{name:name, licenseType:licenseType, location:location, resourceGroup:resourceGroup, id:id, ResourceType:type, State:status}" --only-show-errors -o json | ConvertFrom-Json
                    if( $elasticPools.Count -eq 0) {
                        Write-Output "No Elastic Pools found on Server $($server.name) that require a license update."
                    } else {
                        Write-Output "Found $($elasticPools.Count) Elastic Pools on Server $($server.name) that require a license update."
                    }
                    foreach ($pool in $elasticPools) {
                                        
                        # Collect data before modification
                        $modifiedResources += [PSCustomObject]@{
                            TenantID            = $TenantId
                            SubID               = ($pool.id -split '/')[2]
                            ResourceName        = $pool.name
                            ResourceType        = $pool.ResoureType
                            Status              = $pool.State
                            OriginalLicenseType = $pool.licenseType
                            ResourceGroup       = $pool.resourceGroup
                            Location            = $pool.location
                        }
                        
                        if (-not $ReportOnly) {
                            Write-Output "Updating Elastic Pool '$($pool.name)' on server '$($server.name)' to license type '$LicenseType'..."
                            $result = az sql elastic-pool update --name $pool.name --server $server.name --resource-group $server.resourceGroup --set licenseType=$LicenseType --only-show-errors -o json | ConvertFrom-Json -ErrorAction SilentlyContinue
                            $finalStatus += $result
                            $report["ElasticPoolUpdated"] += $pool.name
                        }
                    }
                }
                catch {
                    Write-Output "Encountered an issue while updating Elastic Pools on server '$($server.name)'. Continuing..."
                }
            }
        }
        catch {
            Write-Error "An error occurred while processing SQL Databases or Elastic Pools: $_"
        }

        # --- Section: Update SQL Instance Pools ---
        try {
            Write-Output "Searching for SQL Instance Pools that require a license update..."
            $instancePoolsQuery = if ($rgFilter) {
                "[?licenseType!='${LicenseType}' && $rgFilter $tagsFilter].{name:name, licenseType:licenseType, location:location, resourceGroup:resourceGroup, id:id, ResourceType:type, State:status}"
            } else {
                "[?licenseType!='${LicenseType}' $tagsFilter].{name:name, licenseType:licenseType, location:location, resourceGroup:resourceGroup, id:id, ResourceType:type, State:status}"
            }
            $instancePools = az sql instance-pool list --query $instancePoolsQuery -o json | ConvertFrom-Json
            $poolsToUpdate = $instancePools | Where-Object { $_.licenseType -ne $LicenseType }
            if($poolsToUpdate.Count -eq 0) {
                Write-Output "No SQL Instance Pools found that require a license update."
            } else {
                Write-Output "Found $($poolsToUpdate.Count) SQL Instance Pools that require a license update."
            }
            foreach ($pool in $poolsToUpdate) {
                
                # Collect data before modification
                $modifiedResources += [PSCustomObject]@{
                    TenantID            = $TenantId
                    SubID               = ($pool.id -split '/')[2]
                    ResourceName        = $pool.name
                    ResourceType        = $pool.ResoureType
                    Status              = $pool.State
                    OriginalLicenseType = $pool.licenseType
                    ResourceGroup       = $pool.resourceGroup
                    Location            = $pool.location
                }
                if (-not $ReportOnly) {
                    Write-Output "Updating SQL Instance Pool '$($pool.name)' in RG '$($pool.resourceGroup)' to license type '$LicenseType'..."
                    $result = az sql instance-pool update --name $pool.name --resource-group $pool.resourceGroup --license-type $LicenseType -o json | ConvertFrom-Json
                    $finalStatus += $result
                }
            }
        }
        catch {
            Write-Error "An error occurred while updating SQL Instance Pools: $_"
        }

        # --- Section: Update DataFactory SSIS Integration Runtimes ---
        try {
            Write-Output "Processing DataFactory SSIS Integration Runtime resources..."
            Get-AzDataFactoryV2 | Where-Object { $_.ProvisioningState -eq "Succeeded" } | ForEach-Object {
                Get-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName | Where-Object { $_.Type -eq "Managed" -and $_.State -ne "Starting" } | ForEach-Object {
                    if ($_.LicenseType -ne $LicenseType) {
                        # Collect data before modification
                        $modifiedResources += [PSCustomObject]@{
                            TenantID            = $TenantId
                            SubID               = ($_.Id -split '/')[2]
                            ResourceName        = $_.Name
                            ResourceType        = "Microsoft.DataFactory/factories/integrationRuntimes"
                            Status              = $_.State
                            OriginalLicenseType = $_.LicenseType
                            ResourceGroup       = $_.ResourceGroupName
                            Location            = $_.Location
                        }
                        # Update the license type to $LicenseType.
                        if (-not $ReportOnly) {
                            $result = Set-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName -Name $_.Name -LicenseType $LicenseType -Force
                            $finalStatus += $result                       
                            Write-Host ([Environment]::NewLine + "-- DataFactory '$($_.DataFactoryName)' integration runtime updated to license type $LicenseType")
                        }
                    }
                }
            }
        }
        catch {
            Write-Error "An error occurred while updating DataFactory SSIS Integration Runtimes: $_"
        }

    }
    catch {
        Write-Error "An error occurred while processing subscription '$($sub.name)': $_"
    }
}

$scriptEndTime = Get-Date
$totalDuration = $scriptEndTime - $scriptStartTime

# --- Final Report ---
Write-Output "`n===== Final Report ====="
Write-Output "Script started at: $scriptStartTime"
Write-Output "Script ended at:   $scriptEndTime"
Write-Output "Total duration:    $($totalDuration.ToString())"

# Export modified resource data to CSV
if ($modifiedResources.Count -gt 0) {
    $csvPath = "ModifiedResources_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $modifiedResources | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Output "CSV report saved to: $csvPath"
} else {
    Write-Output "No resources were marked for modification. No CSV generated."
}

write-Output "Azure SQL Update Script completed"