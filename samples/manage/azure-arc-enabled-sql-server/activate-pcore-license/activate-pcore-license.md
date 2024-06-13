#
# This script performes a scheduled activation of a SQL Server p-core license.
#
# The script accepts the following command line parameters:
#
# -LicenseID            (The specific resource URI)
# -UseInRunbook         (True to use Azure Runbook)
#

param (
    [Parameter (Mandatory= $true)]
    [string] $LicenseId,
    [Parameter (Mandatory= $true)]
    [string] $UseInRunbook
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

#The following block is required for runbooks only
if ($UseInRunbook){

    # Ensures you do not inherit an AzContext in your runbook
    Disable-AzContextAutosave –Scope Process

    $connection = Get-AutomationConnection -Name AzureRunAsConnection

    # Wrap authentication in retry logic for transient network failures
    $logonAttempt = 0
    while(!($connectionResult) -and ($logonAttempt -le 10))
    {
        $LogonAttempt++
        # Logging in to Azure...
        $connectionResult = Connect-AzAccount `
                            -ServicePrincipal `
                            -Tenant $connection.TenantID `
                            -ApplicationId $connection.ApplicationID `
                            -CertificateThumbprint $connection.CertificateThumbprint

        Start-Sleep -Seconds 5
    }
}else{
    # Ensure that the required modules are imported
    # In Runbooks these modules must be added to the automation account manually

    $requiredModules = @(
        "Az.Accounts",
        "Az.Resources"
    )
    $requiredModules | Foreach-Object {CheckModule $_}
}

$currentLicense = Get-AzResource -ResourceId $LicenseId 
$currentLicense.properties.activationState = "Activated"
$currentLicense | Set-AzResource -Force

