param (
    [Parameter (Mandatory=$true)]
    [string]$AzureSubscriptionId,
    [Parameter (Mandatory=$true)]
    [string]$AzureResourceGroupUri,
    [Parameter (Mandatory=$true)]
    [string]$AzureRegion,
    [Parameter (Mandatory=$false)]
    [string]$SqlServerInstanceName,
    [Parameter (Mandatory=$true)]
    [string]$SqlServerAdminAccount,
    [Parameter (Mandatory=$true)]
    [string]$SqlServerAdminPassword,
    [Parameter (Mandatory=$true)]
    [string]$SqlServerVersion,
    [Parameter (Mandatory=$true)]
    [string]$SqlServerEdition,
    [Parameter (Mandatory=$true)]
    [string]$SqlServerProductKey,
    [Parameter (Mandatory=$true)]
    [string]$isoURL,
    [Parameter (Mandatory=$false)]
    [string]$SqlServerCU = "latest"
    
)

# This function checks if the specified module is imported into the session and if not installes and/or imports it
function LoadModule
{
    param (
        [parameter(Mandatory = $true)][string] $name
    )

    $retVal = $true

    if (!(Get-Module -Name $name))
    {
        $retVal = Get-Module -ListAvailable | Where-Object {$_.Name -eq $name}

        if ($retVal)
        {
            try
            {
                Import-Module $name -ErrorAction SilentlyContinue
            }
            catch
            {
                write-host "The request to lload module $($name) failed with the following error:"
                write-host $_.Exception.Message                
                $retVal = $false
            }
        }
        else {

            # If module is not imported, not available on disk, but is in online gallery then install and import
            if (Find-Module -Name $name) {
                Install-Module -Name $name -Force -Verbose -Scope CurrentUser
                try
                {
                Import-Module $name -ErrorAction SilentlyContinue
                }
                catch
                {
                    write-host "The request to lload module $($name) failed with the following error:"
                    write-host $_.Exception.Message                
                    $retVal = $false
                }
            }
            else {

                # If module is not imported, not available and not in online gallery then abort
                write-host "Module $($name) not imported, not available and not in online gallery, exiting."
                EXIT 1
            }
        }
    }

    return $retVal
}

try {

    #Step 0: Ensure PS version and load missing Azure modules 
    #
    # Suppress warnings
    #
    Update-AzConfig -DisplayBreakingChangeWarning $false

    # Load required modules
    $requiredModules = @(
        "AzureAD",    
        "Az.Accounts",
        "Az.ConnectedMachine",
        "Az.ResourceGraph"
    )
    $requiredModules | Foreach-Object {LoadModule $_}
  
    # Step 1: Check if setup.exe is already running and kill it if so
    if (Get-Process setup -ErrorAction SilentlyContinue) {
        Stop-Process -Name setup -Force
        Write-Host "Existing setup.exe process terminated."
    }

    # Step 2: Log in to Azure
    Connect-AzAccount
    $subscription = Get-AzSubscription -SubscriptionId $AzureSubscriptionId -ErrorAction SilentlyContinue
    if (-not $subscription) {
        Write-Error "Azure subscription with ID '$AzureSubscriptionId' does not exist."
        exit
    }
    
    # Step 2: Block auto-onboarding to Arc by tagging the resource group
    $existingResourceGroup = Get-AzResourceGroup -Name $AzureResourceGroupUri -ErrorAction SilentlyContinue

    if ($existingResourceGroup) {
        Write-Host "Resource group '$AzureResourceGroupUri' exists."
    } else {
        Write-Error "Resource group '$AzureResourceGroupUri' does not exist."
        exit
    }    
    $tags = @{"ArcOnboarding" = "Blocked"}
    Set-AzResourceGroup -Name $AzureResourceGroupUri -Tag $tags

    # Step 3: Onboard the VM to Azure Arc
    $hostName = (Get-WmiObject Win32_ComputerSystem).Name

    New-AzConnectedMachine -ResourceGroupName $AzureResourceGroupUri -Name $hostName -Location $AzureRegion

    # Step 4: Automatically download installable media
 
    $isoLocation = "C:\download\SQLServer.iso"
    if (!(Test-Path -Path $isoLocation)) { 
        $freeSpace = (Get-PSDrive -Name C).Free
        $isoSize = (Invoke-WebRequest -Uri $isoURL -Method Head).Headers.'Content-Length'
        if ($freeSpace -gt $isoSize) {
             Start-BitsTransfer -Source $isoURL -Destination $isoLocation
        } else {
             throw "Not enough free space to download the ISO."
        }
    }

    # Step 5: Mount the ISO file as a volume
    $volumeInfo = Mount-DiskImage -ImagePath $isoLocation -PassThru | Get-Volume
    
    # Step 6: Run unattended SQL Server setup from the mounted volume
    $setupPath = ($volumeInfo.DriveLetter + ":\setup.exe")
    $argumentList = "
        /q 
        /ACTION=Install 
        /INSTANCENAME='$($SqlServerInstanceName)' 
        /FEATURES=SQL 
        /INSTANCEDIR=C:\SQL 
        /SQLSYSADMINACCOUNTS='$($SqlServerAdminAccount)' 
        /SQLSVCACCOUNT='$($SqlServerAdminAccount)' 
        /SQLSVCPASSWORD='$($SqlServerAdminPassword)' 
        /AGTSVCACCOUNT='$($SqlServerAdminAccount)' 
        /AGTSVCPASSWORD='$($SqlServerAdminPassword)' 
        /IACCEPTSQLSERVERLICENSETERMS 
        /PID='$($SqlServerProductKey)' 
        /SQLSERVERUPDATE='$($SqlServerCU)' 
        /Edition='$($SqlServerEdition)'
    "
    Start-Process -FilePath $setupPath -ArgumentList $argumentList

    # Step 7: Install SQL Arc extension with LT=PAYG
    $Settings = @{
        SqlManagement = @{ IsEnabled = $true };        
        LicenseType = "PAYG";
        enableExtendedSecurityUpdates = $True;
        esuLastUpdatedTimestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    New-AzConnectedMachineExtension -ResourceGroupName $AzureResourceGroupUri -MachineName $hostName -Name "WindowsAgent.SqlServer" -Publisher "Microsoft.AzureData" -Type "WindowsAgent.SqlServer" -TypeHandlerVersion "1.0" -Settings $settings

    # Step 9: Dismount the ISO file after installation
    Dismount-DiskImage -ImagePath $isoLocation

    # Step 10: Remove the media from the local file system
    Remove-Item -Path $isoLocation

    # Step 8: Display the status of the Azure resource for Arc-enabled SQL Server    
    $query = "
    resources
    | where type =~ 'microsoft.hybridcompute/machines' 
    | where resourceGroup =~ '$($AzureResourceGroupUri)'
    | where properties.detectedProperties.mssqldiscovered == 'true'
    | extend machineIdHasSQLServerDiscovered = id
    | project name, machineIdHasSQLServerDiscovered, resourceGroup, subscriptionId
    | join kind= leftouter (
        resources
        | where type == 'microsoft.hybridcompute/machines/extensions'    | where properties.type in ('WindowsAgent.SqlServer','LinuxAgent.SqlServer')
        | extend machineIdHasSQLServerExtensionInstalled = iff(id contains '/extensions/WindowsAgent.SqlServer' or id contains '/extensions/LinuxAgent.SqlServer', substring(id, 0, indexof(id, '/extensions/')), '')
        | project Extension_State = properties.provisioningState,
        License_Type = properties.settings.LicenseType,
        ESU = iff(notnull(properties.settings.enableExtendedSecurityUpdates), iff(properties.settings.enableExtendedSecurityUpdates == true,'enabled','disabled'), ''),
        Extension_Version = properties.instanceView.typeHandlerVersion,
        machineIdHasSQLServerExtensionInstalled)on $left.machineIdHasSQLServerDiscovered == $right.machineIdHasSQLServerExtensionInstalled
        | where isnotempty(machineIdHasSQLServerExtensionInstalled)
    | project-away machineIdHasSQLServerDiscovered, machineIdHasSQLServerExtensionInstalled
    "
    Search-AzGraph -Query "$($query)"

} catch {
    Write-Error "An error occurred: $_"
    # You can add additional error handling logic here
} finally {
    # Cleanup or other actions that should always run
    Write-Host "Script execution completed."
}
