#
# This script provides a scalable method to switch the license type to pay-as-you-go (aka LicenseIncluded) for all SQL resources in a specific subscription or the entire tenant. By default, the script scans
# all subscriptions the user account has access or a .CSV file with a list of subscriptions. Alternatively, you can specify a single subscription or and a specific resource group. The sripts enumerates the specific 
# resources that have been affected by the change.
#
# The following resources are in scope for the license utilization analysis:
# - Azure SQL databases (vCore-based purchasing model only)
# - Azure SQL elastic pools (vCore-based purchasing model only)
# - Azure SQL managed instances
# - Azure SQL instance pools
# - Azure Data Factory SSIS integration runtimes
# - SQL Servers in Azure virtual machines
#
# The script accepts the following command line parameters:
#
# -SubId [subscription_id] | [csv_file_name]    (Accepts a .csv file with the list of subscriptions)
# -ResourceGroup [resource_goup]                (Optional. Limits the scope to a specific resoure group)
# -LicenseType [license_type_value]             (Optional. Sets the license type to the specified value. Ifnot specified, "LicenseIncluded" is set)
# -FilePath [csv_file_name]                     (Required to save data in a .csv format. Ignored if database parameters are specified)
#

param (
    [Parameter (Mandatory= $false)]
    [string] $SubId,
    [Parameter (Mandatory= $false)]
    [string] $ResourceGroup,
    [Parameter (Mandatory= $false)]
    [ValidateSet("LicenseIncluded", "BasePrice", IgnoreCase=$false)]
    [string] $LicenseType = "LicenseIncluded"
)

function CheckModule ($m) {

    # This function ensures that the specified module is imported into the session
    # If module is already imported - do nothing

    if (!(Get-Module | Where-Object {$_.Name -eq $m})) {
        # If module is not imported, but available on disk then import
        if (Get-Module -ListAvailable | Where-Object {$_.Name -eq $m}) {
            Import-Module $m
        }
        else {
            # If module is not imported, not available on disk, but is in online gallery then install and import
            if (Find-Module -Name $m | Where-Object {$_.Name -eq $m}) {
                Install-Module -Name $m -Force -Verbose -Scope CurrentUser
                Import-Module $m
            }
            else {
                # If module is not imported, not available and not in online gallery then abort
                write-host "Module $m not imported, not available and not in online gallery, exiting."
                EXIT 1
            }
        }
    }
}

#
# Suppress warnings
#
Update-AzConfig -DisplayBreakingChangeWarning $false

$requiredModules = @(
    "Az.Accounts",
    "Az.Compute",
    "Az.DataFactory",
    "Az.Resources",
    "Az.Sql",
    "Az.SqlVirtualMachine"
)
$requiredModules | Foreach-Object {CheckModule $_}

# Subscriptions to scan

$tenantID = (Get-AzureADTenantDetail).ObjectId

if ($SubId -like "*.csv") {
    $subscriptions = Import-Csv $SubId
}elseif($SubId -ne "") {
    $subscriptions = [PSCustomObject]@{SubscriptionId = $SubId} | Get-AzSubscription -TenantID $tenantID
} else {
    $subscriptions = Get-AzSubscription -TenantID $tenantID
}

# Record the start time
$startTime = Get-Date
Write-Host ("Script execution started at: $startTime")

# Calculate usage for each subscription

foreach ($sub in $subscriptions) {

    if ($sub.State -ne "Enabled") { continue }

    try {
        Set-AzContext -SubscriptionId $sub.Id
    } catch {
        write-host "Invalid subscription: " $sub.Id
        continue
    }

    # Get the resource groups 
    if ($ResourceGroup) {
        $rgs = Get-AzResourceGroup -Name $ResourceGroup
    } else {
        $rgs = Get-AzResourceGroup
    }

    foreach ($rg in $rgs) {
        # Get all logical servers
        $servers = Get-AzSqlServer -ResourceGroupName $rg.ResourceGroupName

        # Scan all vCore-based SQL database resources in the subscription
        $servers | Get-AzSqlDatabase | Where-Object { $_.SkuName -ne "ElasticPool" -and $_.Edition -in @("GeneralPurpose", "BusinessCritical", "Hyperscale") } | ForEach-Object {
            if ($_.LicenseType -ne $LicenseType) {
                Set-AzSqlDatabase -ResourceGroupName $_.ResourceGroupName -ServerName $_.ServerName -DatabaseName $_.DatabaseName -LicenseType $LicenseType
                Write-Host ([Environment]::NewLine + "-- Database $_.DatabaseName is set to $LicenseType")
            }
        }
        [system.gc]::Collect()

        # Scan all vCore-based SQL elastic pool resources in the subscription
        $servers | Get-AzSqlElasticPool | Where-Object { $_.Edition -in @("GeneralPurpose", "BusinessCritical", "Hyperscale") } | ForEach-Object {
            if ($_.LicenseType -ne $LicenseType) {
                Set-AzSqlElasticPool -ResourceGroupName $_.ResourceGroupName -ServerName $_.ServerName -ElasticPoolName $_.ElasticPoolName -LicenseType $LicenseType
                Write-Host ([Environment]::NewLine + "-- ElasticPool $_.ElasticPoolName is set to $LicenseType")
            }
        } 
        [system.gc]::Collect()

        # Scan all SQL managed instance resources in the subscription
        Get-AzSqlInstance | Where-Object { $_.InstancePoolName -eq $null } | ForEach-Object {
            if ($_.LicenseType -ne $LicenseType) {
                Set-AzSqlInstance -ResourceGroupName $_.ResourceGroupName -ServerName $_.ServerName -InstanceName $_.InstanceName -LicenseType $LicenseType
                Write-Host ([Environment]::NewLine + "-- Instance $_.InstanceName is set to $LicenseType")
            }      
        }
        [system.gc]::Collect()

        # Scan all instance pool resources in the subscription
        Get-AzSqlInstancePool | Foreach-Object {
            if ($_.LicenseType -ne $LicenseType) {
                Set-AzSqlInstancePool -ResourceGroupName $_.ResourceGroupName -ServerName $_.ServerName -InstanceName $_.InstanceName -LicenseType $LicenseType
                Write-Host ([Environment]::NewLine + "-- InstancePool $_.InstanceName is set to $LicenseType")
            }
        }
        [system.gc]::Collect()

        # Scan all SSIS integration runtime resources in the subscription
        Get-AzDataFactoryV2IntegrationRuntime | Where-Object { $_.State -eq "Started" -and $_.NodeSize -ne $null } | ForEach-Object {
            if ($_.LicenseType -ne $LicenseType) {
                # Set the license type to $LicenseType
                Set-AzDataFactoryV2IntegrationRuntime -ResourceGroupName $_.ResourceGroupName -DataFactoryName $_.DataFactoryName -Name $_.Name -LicenseType $LicenseType
                Write-Host ([Environment]::NewLine + "-- DataFactory $_.DataFactoryName is set to $LicenseType")
            }
        }
        [system.gc]::Collect()

        # Scan all SQL VMs in the subscription
        Get-AzVM | Where-Object { $_.StorageProfile.ImageReference.Offer -like "*sql*" -and $_.ProvisioningState -eq "Succeeded" } | ForEach-Object {
            $vmName = $_.Name
            $resourceGroupName = $_.ResourceGroupName
        
            # Get the SQL configuration for the VM
            $sqlConfig = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "SqlIaaSAgent"
            
            if ($sqlConfig -ne $null) {
                $licenseType = $sqlConfig.Settings.LicenseType
        
                if ($licenseType -ne $LicenseType) {
                    # Set the license type to $LicenseType
                    Set-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name "SqlIaaSAgent" -Publisher "Microsoft.SqlServer.Management" -ExtensionType "SqlIaaSAgent" -TypeHandlerVersion "1.5" -Settings @{ "LicenseType" = $LicenseType }
                    Write-Host ([Environment]::NewLine + "-- SQL VM $vmName is set to $LicenseType")
                }
        
            }
        }
        [system.gc]::Collect()

    }
}

# Record the end time
$endTime = Get-Date
Write-Host ("Script execution ended at: $endTime")
