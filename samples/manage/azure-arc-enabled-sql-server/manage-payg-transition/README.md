---
services: Azure Arc-enabled SQL Server
platforms: Azure
author: anosov1960
ms.author: sashan
ms.date: 12/01/2024
---

# Manage Transition to Azure Pay-as-you-go subscription

This script provides a scaleable solution to transition the SQL Server resources an Arc or Azure to Azure Pay-as-you-go subscription as a single step. 

You can specify a single subscription to scan, or provide a list of subscriptions as a .CSV file.
If not specified, all subscriptions your role has access to are scanned.

## Prerequisites

- You must have at least a *Azure Connected Machine Resource Administrator* role in each subscription you modify.
- The Azure extension for SQL Server is updated to version 1.1.2230.58 or newer.
- You must be connected to Azure AD and logged in to your Azure account. If your account have access to multiple tenants, make sure to log in with a specific tenant ID.

## Prerequisites

- **PowerShell 5+.**
- **User running needs to be Azure Subscription owner or contributor to be able to run the script.**  


---

# Launching the script

The script accepts the following command line parameters:

| **Parameter** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;  | **Value** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; | **Description** |
|:--|:--|:--|
|`-SubId`|`<subscription_id>` *or* `<file name>`|*Optional*: Subscription id or a .csv file with the list of subscriptions<sup>1</sup>. If not specified all subscriptions will be transitioned.|
|`-ResourceGroup` |`<name>`|*Optional*: Limits the scope of transition to a specified resource|
|`-RunAt` |`YYYY-MM-DD HH:MM:SS` |*Optional*: Sets the transition time in UTC time zone. E.g. 2025-05-01 14:00:00 means May 1, 2025 at 2pm UTC time. If not specified, the transition will be executed immediately.|
|`-UsePcoreLicense` | `Yes`, `No` |*Optional*. Passed to Arc script to control PCore licensing behavior. Set to `No` if not specified.|
|`-AutomationAccount`| `<name>`|*Required* if `-RunAt` is specified. The script will automatically create an automation account with this name unless one with this name alreday exists. It will be used for the “General” runbook import operation. |
|`-Location`|`<region>`|*Required* if `-RunAt` is specified. Azure region for the “General” runbook import operation.|

<sup>1</sup>You can create a .csv file using the following command and then edit to remove the subscriptions you don't  want to scan.
```PowerShell
Get-AzSubscription | Export-Csv .\mysubscriptions.csv -NoTypeInformation
```


## How It Works

This script internally runs the following scripts 
   - `set-azurerunbook.ps1` - imports & publishes the helper runbook that and run if a scheduled execution is selected. 
   - `modify-azure-sql-license-type.ps1` - configures the Azure SQL resources to pay-as-you-go
   - `modify-license-type.ps1` configures the existing Arc SQL resources to pay-as-you-go

The dependent scripts are downloaded to `.\PaygTransitionDownloads\`. It is created automatically if doesn't exist. The downloaded scripts are refreshed automatically on each run to ensure that the up-to-date version is used.


## Examples

### Run Immediately
#### Both Environments

```powershell
.\manage-pay-transition.ps1 -Target Both -RunMode Single -cleanDownloads $true `
    -UsePcoreLicense Yes `
    -targetSubscription "00000000-0000-0000-0000-000000000000" `
    -targetResourceGroup "MyRG" `
    -AutomationAccountName "MyAutoAcct" `
    -Location "EastUS"
````

### Arc Only, Single Run, With Cleanup
```powershell
.\schedule-pay-transition.ps1 `
  -Target Arc `
  -RunMode Single `
  -cleanDownloads $true `
  -UsePcoreLicense Yes `
  -targetSubscription "11111111-1111-1111-1111-111111111111" `
  -targetResourceGroup "ArcRG"
````

### Both Azure & Arc, Single Run, Full Parameters
```powershell
.\schedule-pay-transition.ps1 `
  -Target Both `
  -RunMode Single `
  -cleanDownloads $true `
  -UsePcoreLicense No `
  -targetSubscription "22222222-2222-2222-2222-222222222222" `
  -targetResourceGroup "HybridRG" `
  -AutomationAccountName "MyAutomationAccount" `
  -Location "EastUS"
```
### Scheduled-Run Scenarios

#### Schedule Daily for Azure Only
```powershell
.\schedule-pay-transition.ps1 `
  -Target Azure `
  -RunMode Scheduled
```
#### Schedule Daily for Arc Only
```powershell
.\schedule-pay-transition.ps1 `
  -Target Arc `
  -RunMode Scheduled
```

#### Schedule Daily for Both Environments
```powershell
.\schedule-pay-transition.ps1 `
  -Target Both `
  -RunMode Scheduled
```