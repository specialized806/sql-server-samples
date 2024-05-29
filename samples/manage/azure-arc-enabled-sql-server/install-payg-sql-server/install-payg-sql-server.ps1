param (
    [string]$AzureSubscriptionId,
    [string]$AzureResourceGroupUri,
    [string]$location,
    [string]$SqlServerInstanceName,
    [string]$SqlServerAdminAccount,
    [string]$SqlServerAdminPassword,
    [string]$SqlServerVersion,
    [string]$SqlServerEdition,
    [string]$SqlServerProductKey,
    [string]$SqlServerCU = "latest",
    [string]$isoURL # URL to the ISO file
)

try {
    # Step 0: Check if setup.exe is already running and kill it if so
    if (Get-Process setup -ErrorAction SilentlyContinue) {
        Stop-Process -Name setup -Force
        Write-Host "Existing setup.exe process terminated."
    }

    # Step 1: Log in to Azure
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
    $localPath = "C:\path\to\download\SQLServer.iso"
    $freeSpace = (Get-PSDrive -Name C).Free
    $isoSize = (Invoke-WebRequest -Uri $isoURL -Method Head).Headers.'Content-Length'

    if ($freeSpace -gt $isoSize) {
         Start-BitsTransfer -Source $isoURL -Destination $localPath
    } else {
         throw "Not enough free space to download the ISO."
    }


    # Step 6: Mount the ISO file as a volume
    $volumeInfo = Mount-DiskImage -ImagePath $localPath -PassThru | Get-Volume
    
    # Step 7: Run unattended SQL Server setup from the mounted volume
    $setupPath = ($volumeInfo.DriveLetter + ":\setup.exe")
    Start-Process -FilePath $setupPath -ArgumentList "/q /ACTION=Install /INSTANCENAME=$SqlServerInstanceName /FEATURES=SQL /INSTANCEDIR=C:\SQL /SQLSYSADMINACCOUNTS=$SqlServerAdminAccount /SQLSVCACCOUNT=$SqlServerAdminAccount /SQLSVCPASSWORD=$SqlServerAdminPassword /AGTSVCACCOUNT=$SqlServerAdminAccount /AGTSVCPASSWORD=$SqlServerAdminPassword /IACCEPTSQLSERVERLICENSETERMS /PID=$SqlServerProductKey /SQLSERVERUPDATE=$SqlServerCU"

    # Step 8: Dismount the ISO file after installation
    Dismount-DiskImage -ImagePath $localPath

    # Step 9: Remove the media from the local file system
    Remove-Item -Path $localPath

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
