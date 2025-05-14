
<#
.SYNOPSIS
    Updates the license type for Azure Arc SQL resources to a specified license and license related options.  

.DESCRIPTION
    The script updates the license related settings of the SQL extenstion resources in a specified Entra ID tenant. You can specify a particular subscription, resource group or an individual connected machine. 
    You can also provide a list of subscriptions as a .CSV file. 
    By default, all subscriptions in your current tenant id are scanned.

.VERSION
    3.0.5 - Initial version.

.PARAMETER SubId
    A single subscription ID or a CSV file name containing a list of subscriptions.

.PARAMETER ResourceGroup
    Optional. Limit the scope to a specific resource group.

.PARAMETER MachineName 
    Optional. A single machine name or a CSV file name containing a list of machine names.

.PARAMETER LicenseType
    Optional. License type to set. Allowed values: "PAYG", "Paid" or "LicenseOnly"

.PARAMETER ConsentToRecurringPAYG 
    Optional. Consents to enabling the recurring PAYG billing. LicenseType must be "PAYG". Applies to CSP subscriptions only.

.PARAMETER UsePcoreLicense
    Optional. Opts in to use unlimited virtualization license if the value is "Yes", or opts out if the value is "No". To opt in, the license type must be "Paid" or "PAYG"

.PARAMETER EnableESU
    Optional. Enables the ESU policy if the value is "Yes" or disables it if the value is "No". To enable, the license type must be "Paid" or "PAYG"

.PARAMETER Force
    Optional. Forces the chnahge of the license type to the specified value on all installed extensions. If not forced, the changes will apply only to the extensions where the license type is undefined.    

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
    [Parameter (Mandatory=$false)]
    [string] $SubId,

    [Parameter (Mandatory= $false)]
    [string] $ResourceGroup,

    [Parameter (Mandatory= $false)]
    [string] $MachineName,

    [Parameter (Mandatory= $false)]
    [ValidateSet("PAYG","Paid","LicenseOnly", IgnoreCase=$false)]
    [string] $LicenseType,

    [Parameter (Mandatory= $false)]
    [ValidateSet("Yes","No", IgnoreCase=$false)]
    [string] $UsePcoreLicense,

    [Parameter (Mandatory= $false)]
    [ValidateSet("Yes","No", IgnoreCase=$false)]
    [string] $EnableESU,

    [Parameter (Mandatory= $false)]
    [switch] $Force,

    [Parameter (Mandatory= $false)]
    [object] $ExclusionTags,

    [Parameter (Mandatory= $false)]
    [string] $TenantId,

    [Parameter (Mandatory= $false)]
    [switch] $ReportOnly,
   
    [Parameter (Mandatory= $false)]
    [switch] $UseManagedIdentity

)

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
    $TenantId = $context.Tenant.Id
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
try{
    Import-Module AzureAD -UseWindowsPowerShell
}
catch{
    Write-Output "Can't import module AzureAD"
}
try{
    Import-Module Az.Accounts
}catch{
    Write-Output "Can't import module Az.Accounts"
}
try{
    Import-Module Az.ConnectedMachine
}
catch{
    Write-Output "Can't import module Az.ConnectedMachine"
}
try{
    Import-Module Az.ResourceGraph
}
catch{
    Write-Output "Can't import module Az.ResourceGraph"
}

$modifiedResources = @()

if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId
}elseif($SubId -ne "") {
    Write-Output "Passed Subscription $($SubId)"
    $subscriptions = [PSCustomObject]@{SubscriptionId = $SubId} | Get-AzSubscription -TenantID $TenantId
}else {
    $subscriptions = Get-AzSubscription -TenantID $TenantId
}

# Handle MachineName input (single or CSV)
$machineNames = @()
if ($MachineName) {
    if ($MachineName -like "*.csv") {
        try {
            $machines = Import-Csv $MachineName
            foreach ($m in $machines) {
                if ($m.MachineName) {
                    $machineNames += $m.MachineName
                }
            }
            Write-Output "Loaded $($machineNames.Count) machine names from CSV."
        } catch {
            Write-Error "Failed to import machine names from CSV: $_"
            exit 1
        }
    } else {
        $machineNames += $MachineName
    }
}

Write-Host ([Environment]::NewLine + "-- Scanning subscriptions --")

foreach ($sub in $subscriptions) {
    if ($sub.State -ne "Enabled") {continue}

    try {
        Set-AzContext -SubscriptionId $sub.Id #Removed TenantID by Sunil
    }catch {
        write-host "Invalid subscription: $($sub.Id)"
        {continue}
    }

    # Consent tag enforcement on the CSP subscriptions
     # Add or update ConsentToRecurringPAYG setting if applicable
        if ($ConsentToRecurringPAYG -eq "Yes") {
            $isPayg = ($LicenseType -eq "PAYG") -or ($settings["LicenseType"] -eq "PAYG")
            if ($isPayg) {
                if (-not $settings.ContainsKey("ConsentToRecurringPAYG") -or -not $settings["ConsentToRecurringPAYG"]["Consented"]) {
                    $settings["ConsentToRecurringPAYG"] = @{
                        "Consented" = $true;
                        "ConsentTimestamp" = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    }
                    $WriteSettings = $true
                }
            }
        }

    Write-Output "Collecting list of resources to update"
    $query = "
    resources
    |  where type =~ 'microsoft.hybridcompute/machines/extensions'
    | where subscriptionId =~ '$($sub.Id)'
    | extend extensionPublisher = tostring(properties.publisher), 
    extensionType = tostring(properties.type), provisioningState = tostring(properties.provisioningState)
    | parse id with * '/providers/Microsoft.HybridCompute/machines/' machineName '/extensions/' *
    | where extensionPublisher =~ 'Microsoft.AzureData'
    | where provisioningState =~ 'Succeeded'
    | where properties.settings.LicenseType!='$LicenseType'
    | join kind=leftouter (
    resources
    | where type == 'microsoft.azurearcdata/sqlserverinstances'
    | project machineName= name, edition = properties.edition, mytags = tags"
   $query += ") on machineName"
    
    if ($ResourceGroup) {
        $query += "| where resourceGroup =~ '$($ResourceGroup)'"
    }

    if ($machineNames.Count -gt 0) {
        $machineFilter = $machineNames | ForEach-Object { "'$_'" } | -join ", "
        $query += "| where machineName in~ ($machineFilter)"
    } 
    
    $query += "
    | project machineName, extensionName = name, resourceGroup, location, subscriptionId, extensionPublisher, extensionType, properties,provisioningState, edition
    "
    $query
    $resources = Search-AzGraph -Query "$($query)" 
    Write-Output "Found $($resources.Count) resource(s) to update"
    $count = $resources.Count
    
    while($count -gt 0) {
        $count-=1
        Write-Output "VM-$($count)"
        write-Output "VM - $($resources[$count].MachineName)"
        $setID = @{
            MachineName = $resources[$count].MachineName
            Name = $resources[$count].extensionName
            ResourceGroup = $resources[$count].resourceGroup
            Location = $resources[$count].location
            SubscriptionId = $resources[$count].subscriptionId
            Publisher = $resources[$count].extensionPublisher
            ExtensionType = $resources[$count].extensionType
            Edition = $resources[$count].edition
        }

        write-Output "VM - $($setID.MachineName)"
        write-Output "   ResourceGroup - $($setID.ResourceGroup)"
        write-Output "   Location - $($setID.Location)"
        write-Output "   SubscriptionId - $($setID.SubscriptionId)"
        write-Output "   ExtensionType - $($setID.ExtensionType)"
        
        # Get connected machine info
        $sqlvm = Get-AzConnectedMachine -Name $setID.MachineName -ResourceGroup $setID.ResourceGroup | Select-Object Name, Tags, Status

        # Collect data before modification
        $modifiedResources += [PSCustomObject]@{
            TenantID            = $TenantId
            SubID               = $setID.SubscriptionId
            ResourceName        = $setID.MachineName
            ResourceType        = $setID.ExtensionType
            Status              = $sqlvm.Status
            OriginalLicenseType = $settings.LicenseType
            ResourceGroup       = $setID.ResourceGroup
            Location            = $setID.Location
            # Cores             <To be added>
        }

        $excludedByTags = $false
        foreach ($tag in $tagTable.Keys){
            if($sqlvm.Tags.ContainsKey($tag))
            {
                if($sqlvm.Tags[$tag] -eq $tagTable[$tag]){
                    $excludedByTags=$true
                    $value = $tagTable[$tag]
                    write-Output "Exclusion tag $($tag):$value. Skipping..."
                    Break;
                }
            }
        }
        if(!$excludedByTags){
           
        
        $WriteSettings = $false
        $settings = $resources[$count].properties.settings | ConvertTo-Json | ConvertFrom-Json
        $ext = Get-AzConnectedMachineExtension -Name $setID.Name -ResourceGroupName $setID.ResourceGroup -MachineName $setID.MachineName
        if($ext.ProvisioningState -ne "Succeeded") {
            write-Output "Extension is not in a valid state. Skipping..."
            {continue}
        } else {
            $LO_Allowed = (!$settings["enableExtendedSecurityUpdates"] -and !$EnableESU) -or  ($EnableESU -eq "No")
            
            write-Output "   LicenseType - $($settings.LicenseType)"

            if ($LicenseType) {
                if (($LicenseType -eq "LicenseOnly") -and !$LO_Allowed) {
                    write-Output "ESU must be disabled before license type can be set to $($LicenseType)"
                } else {
                    if ($ext.Setting["LicenseType"]) {
                        if ($Force) {
                            $ext.Setting["LicenseType"] = $LicenseType
                            $WriteSettings = $true
                        }
                    } else {
                        $ext.Setting["LicenseType"] = $LicenseType
                        $WriteSettings = $true
                    }
                }
            }
            
            if ($setID.Edition -eq "Express") {
                $LicenseType = "LicenseOnly"
            }

            if ($EnableESU) {
                if (($ext.Setting["LicenseType"] -in ("Paid","PAYG")) -or  ($EnableESU -eq "No")) {
                    $ext.Setting["enableExtendedSecurityUpdates"] = ($EnableESU -eq "Yes")
                    $ext.Setting["esuLastUpdatedTimestamp"] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    $WriteSettings = $true
                } else {
                    write-Output "The configured license type does not support ESUs" 
                }
            }
            
            if ($UsePcoreLicense) {
                if (($ext.Setting["LicenseType"] -in ("Paid","PAYG")) -or  ($UsePcoreLicense -eq "No")) {
                    $ext.Setting["UsePhysicalCoreLicense"] = @{
                        "IsApplied" = ($UsePcoreLicense -eq "Yes");
                        "LastUpdatedTimestamp" = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    }
                    $WriteSettings = $true
                } else {
                    write-Output "The configured license type does not support ESUs" 
                }
            }
            write-Output "   Write Settings - $($WriteSettings)"
            if (-not $ReportOnly) {
                If ($WriteSettings) {
                    try { 
                        $ext | Set-AzConnectedMachineExtension -Name $setID.Name -ResourceGroupName $setID.ResourceGroup -MachineName $setID.MachineName -NoWait -ErrorAction SilentlyContinue | Out-Null
                        Write-Output "Updated -- Resource group: [$($setID.ResourceGroup)], Connected machine: [$($setID.MachineName)]"
                    } catch {
                        write-Output "The request to modify the extension object failed with the following error:"
                        continue
                    }
                }
            } else {
                Write-Output "ReportOnly mode enabled. Skipping modification for: $($setID.MachineName)"
            }
        }
    }
    }
}

# Export modified resource data to CSV
if ($modifiedResources.Count -gt 0) {
    $csvPath = "ModifiedResources_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $modifiedResources | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Output "CSV report saved to: $csvPath"
} else {
    Write-Output "No resources were marked for modification. No CSV generated."
}

write-Output "Arc SQL Update Script completed"
