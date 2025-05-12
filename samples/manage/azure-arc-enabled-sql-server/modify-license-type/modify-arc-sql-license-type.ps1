
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
    [switch] $ReportOnly
)

function Connect-Azure {
    [CmdletBinding()]
    param(
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
    try {
        $ctx = Get-AzContext -ErrorAction Stop
        if (-not $ctx.Account) { throw }
        Write-Output "Already connected to Azure PowerShell as: $($ctx.Account)"
    }
    catch {
        Write-Output "Not connected to Azure PowerShell. Running Connect-AzAccount..."
        if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
            Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        }
        else {
            Connect-AzAccount -ErrorAction Stop | Out-Null
        }
        $ctx = Get-AzContext
        Write-Output "Connected to Azure PowerShell as: $($ctx.Account)"
    }

    # 3) Sync Azure CLI if available
    if (Get-Command az -ErrorAction SilentlyContinue) {
        try {
            Write-Output "Check if az CLI is loged on..."
            $acct = az account show --output json | ConvertFrom-Json
            Write-Output "az: $($acct)"
            if($null -eq $acct)
            {
                Write-Output "Azure CLI not logged in. Running az login..."
                if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
                    az login --identity | Out-Null
                }
                else {
                    az login | Out-Null
                }
                $acct = az account show --output json | ConvertFrom-Json
            }
        }
        catch {
            Write-Output "Azure CLI not logged in. Running az login..."
            if ($UseManagedIdentity -or $envType -eq 'AzureAutomation') {
                az login --identity | Out-Null
            }
            else {
                az login | Out-Null
            }
            $acct = az account show --output json | ConvertFrom-Json
        }
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

# Ensure connection with both PowerShell and CLI.
Connect-Azure
$context = Get-AzContext -ErrorAction SilentlyContinue
Write-Output "Connected to Azure as: $($context.Account)"

if (-not $TenantId) {
    $TenantId = $context.Tenant.Id
    Write-Output "No TenantId provided. Using current context TenantId: $TenantId"
} else {
    Write-Output "Using provided TenantId: $TenantId"
}

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

    <#if($tagTable.Keys.Count -gt 0) {
        $query += "| where "
        $tagcount = $tagTable.Keys.Count
        foreach ($tag in $tagTable.Keys) {
            $tagcount --
            $query += "(mytags['$($tag)'] != '$($tagTable[$tag])')"
            if($tagcount -gt 0) {
                $query += " and "
            }
        }
    }#>

    $query += ") on machineName"
    
    if ($ResourceGroup) {
        $query += "| where resourceGroup =~ '$($ResourceGroup)'"
    }

    if ($MachineName) {
        $query += "| where machineName =~ '$($MachineName)'"
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
