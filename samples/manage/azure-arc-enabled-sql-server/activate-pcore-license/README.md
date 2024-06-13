---
services: Azure SQL
platforms: Azure
author: anosov1960
ms.author: sashan
ms.date: 06/12/2024
---

# Overview

This script performes a scheduled activation of a SQL Server p-core license.

# Required permissions

Your RBAC role must include the following permissions:

- Microsoft.AzureArcData/SqlLicenses/read
- Microsoft.AzureArcData/SqlLicenses/write
- Microsoft.Management/managementGroups/read
- Microsoft.Resources/subscriptions/read
- Microsoft.Resources/subscriptions/resourceGroups/read
- Microsoft.Support/supporttickets/write

# Launching the script

The script accepts the following command line parameters:

| **Parameter** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;  | **Value** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; | **Description** |
|:--|:--|:--|
|-LicenseId| License resource URI |
|-UseInRunbook| \$True or \$False (default) | Optional: must be $True when executed as a Runbook|


## Example 

The following command activate the license 

```PowerShell
.\activate-pcore-license.ps1 -LicenseID <rsource URI>
```

# Running the script using Cloud Shell

To run the script in the Cloud Shell, use the following steps:

1. Launch the [Cloud Shell](https://shell.azure.com/). For details, read [PowerShell in Cloud Shell](https://aka.ms/pscloudshell/docs).

2. Upload the script to the shell using the following command:

    ```console
    curl https://raw.githubusercontent.com/anosov1960/sql-server-samples/master/samples/manage/azure-arc-enabled-sql-server/activate-pcore-license/activate-pcore-license.md -o activate-pcore-license.ps1
    ```

3. Run the script with a set of parameters that reflect your desired configuration.

    ```console
   .\activate-pcore-license.ps1 -licenseID <resource URI>
    ```

> [!NOTE]
> - To paste the commands into the shell, use `Ctrl-Shift-V` on Windows or `Cmd-v` on MacOS.
> - The `curl` command will copy the script directly to the home folder associated with your Cloud Shell session.

# Running the script as a Azure runbook

You can scahedule to run the the command as a runbook. To set it up using Azure Portal, follow these steps.

1. Open a command shell on your device and run this command. It will copy the script to your local folder.
```console
curl https://raw.githubusercontent.com/anosov1960/sql-server-samples/master/samples/manage/azure-arc-enabled-sql-server/activate-pcore-license/activate-pcore-license.md -o activate-pcore-license.ps1
```
2. [Create a new automation account](https://ms.portal.azure.com/#create/Microsoft.AutomationAccount)  or open an existing one.
1. Select *Run as accounts* in the **Account Settings** group, open the automatically created *Azure Run As Account* and note or copy the Display Name property. 
1. Select *Runbooks* in the **Process automation** group and click on *Import a runbook*, select the file you downloaded in Step 1 and click **Create**.
1. When import is completed, click the *Publish* button.
1. From the runbook blade, click on the *Link to schedule* button and select an existing schedule or create a new one with the desired frequency of runs and the expiration time.
1. Click on *Parameters and run settings* and specify the following parameters:
    - LICENSEID. Put in teh resourec URI
    - USEINRUNBOOKS. Select True to activate the logic that authenticates the runbook using the *Azure Run As Account*.
1. Click **OK** to link to the schedule and **OK** again to create the job.

For more information about the runbooks, see the [Runbook tutorial](https://docs.microsoft.com/en-us/azure/automation/learn/automation-tutorial-runbook-textual-powershell)
