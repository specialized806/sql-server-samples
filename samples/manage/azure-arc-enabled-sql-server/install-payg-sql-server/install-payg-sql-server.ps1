param (
    [Parameter (Mandatory=$true)]
    [string]$AzureSubscriptionId,
    [Parameter (Mandatory=$true)]
    [string]$AzureResourceGroupUri,
    [Parameter (Mandatory=$true)]
    [string]$location,
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
    [Parameter (Mandatory=$false)]
    [string]$SqlServerCU = "latest",
    [Parameter (Mandatory=$false)]
    [string]$isoLocation = "C:\download\SQLServer.iso"
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
    # ISO URL for each version
    $isoURL @{
        2012 = "";
        2014 = "";
        2016 = "";
        2019 = "";
        2022 = "https://download.microsoft.com/download/7/c/1/7c14e92e-bdcb-4f89-b7cf-93543e7112d1/SQLServer2019-x64-ENU-Dev.iso"
    }

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
    az login
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
    az group update --name $AzureResourceGroupUri --tags "ArcOnboarding=Blocked"

    # Step 3: Onboard the VM to Azure Arc
    $hostName = (Get-WmiObject Win32_ComputerSystem).Name

    az arc connectedmachine create --resource-group $AzureResourceGroupUri --name $hostName --location $location

    # Step 4: Install SQL Arc extension with LT=PAYG
    az connectedmachine extension create --machine-name $hostName --resource-group $AzureResourceGroupUri --name "WindowsAgent.SqlServer" --type "WindowsAgent.SqlServer" --publisher "Microsoft.AzureData" --settings '{"LicenseType":"PAYG", "SqlManagement": {"IsEnabled":true}}'
 

    # Step 5: Automatically download installable media
 
    if (!(Test-Path -Path $isoLocation)) { 
        $freeSpace = (Get-PSDrive -Name C).Free
        $isoSize = (Invoke-WebRequest -Uri $isoURL[$SqlServerVersion] -Method Head).Headers.'Content-Length'
        if ($freeSpace -gt $isoSize) {
             Start-BitsTransfer -Source $isoURL[$SqlServerVersion] -Destination $isoLocation
        } else {
             throw "Not enough free space to download the ISO."
        }
    }

    # Step 6: Mount the ISO file as a volume
    $volumeInfo = Mount-DiskImage -ImagePath $isoLocation -PassThru | Get-Volume
    
    # Step 7: Run unattended SQL Server setup from the mounted volume
    $setupPath = ($volumeInfo.DriveLetter + ":\setup.exe")
    Start-Process -FilePath $setupPath -ArgumentList "/q /ACTION=Install /INSTANCENAME=$SqlServerInstanceName /FEATURES=SQL /INSTANCEDIR=C:\SQL /SQLSYSADMINACCOUNTS=$SqlServerAdminAccount /SQLSVCACCOUNT=$SqlServerAdminAccount /SQLSVCPASSWORD=$SqlServerAdminPassword /AGTSVCACCOUNT=$SqlServerAdminAccount /AGTSVCPASSWORD=$SqlServerAdminPassword /IACCEPTSQLSERVERLICENSETERMS /PID=$SqlServerProductKey /SQLSERVERUPDATE=$SqlServerCU"

    # Step 8: Dismount the ISO file after installation
    Dismount-DiskImage -ImagePath $isoLocation

    # Step 9: Remove the media from the local file system
    Remove-Item -Path $isoLocation

    # Step 10: Display the status of the Azure resource
    az resource show --ids $AzureResourceGroupUri

    # Step 11: Verify the presence of the Arc-enabled SQL Server
    az sql arc list --resource-group $AzureResourceGroupUri
} catch {
    Write-Error "An error occurred: $_"
    # You can add additional error handling logic here
} finally {
    # Cleanup or other actions that should always run
    Write-Host "Script execution completed."
}
