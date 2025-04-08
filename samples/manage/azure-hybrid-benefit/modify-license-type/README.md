---
services: Azure SQL
platforms: Azure
author: anosov1960,rodrigomonteiro-gbb
ms.author: sashan.romontei
ms.date: 04/08/2025
---

# Overview

This script provides a scaleable solution to change the license type of various Azure SQL resources within the selected scope. It automates the process of modifying license settings for SQL Databases, Elastic Pools, SQL Managed Instances, SQL Instance Pools, SQL Virtual Machines, and DataFactory SSIS Integration Runtimes. The script supports targeting a single subscription, a list of subscriptions defined in a CSV file, or all accessible subscriptions. Optionally, it can also start resources that are stopped (if the -ForceStartOnResources parameter is enabled).

This script is designed to help administrators standardize SQL licensing across their Azure environment by automating license updates. It accepts a subscription ID or CSV file (for a list of subscriptions). If no subscription is specified, it defaults to updating resources in all accessible subscriptions.

# Target Resource Types

- SQL Virtual Machines: Updates license types after checking if the VM is running. If not, it can optionally start the VM to perform the update.
- SQL Managed Instances: Detects instances that are stopped or not in the "Ready" state and can force them to start before updating.
- SQL Databases & Elastic Pools: Scans individual SQL servers to locate databases and elastic pools with a different license type and updates them accordingly.
- SQL Instance Pools: Locates instance pools that require an update.
- DataFactory SSIS Integration Runtimes: Checks for integration runtimes with an out-of-date license setting and updates them.

# Required Permissions
The automation account needs to have the bellow permissions in order to be able to successfully run the Runbook and update all the SQL Server resources license type:

1. **SQL DB Contributor**: *SQL DB Contributor role*. 
1. **SQL Managed Instance Contributor**: *SQL Managed Instance Contributor*
1. **SQL Server Contributor**: *SQL Managed Instance Contributor*
1. **Data Factory Contributor**: *Data Factory Contributor role*.
1. **Virtual Machine Contributor**: *Virtual Machine Contributor role*. 

A *Subscription Contributor* role has sufficient permissions to mdify any of the above resources. 

# Interactive Reporting

The script logs steps along the process and compiles a final report summarizing which resources were updated in each category.

# Integration with Azure Authentication

The scripts is seamlessly integrated with Azure Authentication. It uses managed identity authentication (via Connect-AzAccount -Identity and az login --identity) to connect to your Azure environment securely.

# Script parameters


| **Parameter** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;  | **Value** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; | **Description** |
|:--|:--|:--|
|-SubId|subscription_id *or* a file_name|Optional: Subscription id or a .csv file with the list of subscriptions<sup>1</sup>. If not specified all subscriptions will be scanned|
|-ResourceGroup |resource_group_name|Optional: Limits the scope  to a specific resource group|
|-LicenseType | "LicenseIncluded" (default) or "BasePrice" | Optional: Sets the license type to the specified value |
|-ForceStartOnResources| |(Optional) When enabled, the script will attempt to start SQL VMs and SQL Managed Instances if they are not running before applying the update.|

# Logging & Error Handling

The script logs key actions to the console and captures error messages using Write-Error. Check the console output for a summary report detailing which resources were updated.

# Customizations

You might want to customize the script’s logging or incorporate additional logging (e.g., writing to a file or Azure Log Analytics) to integrate seamlessly with your monitoring and reporting workflow.

# Script execution examples

## Example 1

The following command will scan all the subscriptions to which the user has access to, and set the license type to pay-as-you-go on all SQL resources in each subscription that the user has access to.

```PowerShell
.\modify-license-type.ps1 -LicenseType LicenseIncluded
```

## Example 2

The following command will scan a specific subscription, and set the license type to pay-as-you-go on all SQL resources.

```PowerShell
.\modify-license-type.ps1 -SubId <sub_id> -LicenseType LicenseIncluded 
```

## Example 3

The following command will scan the resource group `<resource_group_name>` in the subscription `<sub_id>`, set the license type value to pay-as-you-go. If the resource group has SQL VMs in the offline state, it will start each VM before applying the change, and then stop it. 

```PowerShell
.\modify-license-type.ps1 -SubId <sub_id> -ResourceGroup <resource_group_name> -LicenseType LicenseIncluded -ForceStartOnResources
```

# Running the script from your PC

1. Connect to Azure AD. You must specify `<tenant_id>` if you have access to more than one AAD tenants.

    ```console
   Connect-AzureAD -TenantID <tenant_id>
    ```
1. Open a command shell on your device and download the script the script to your local folder.

```console
curl https://raw.githubusercontent.com/microsoft/sql-server-samples/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-license-type.ps1
```
1. Execute the command as shown by the examples  

# Running the script using Cloud Shell

This option is recommended because Cloud shell has the Azure PowerShell modules pre-installed and you are automatically authenticated.  Use the following steps to run the script in Cloud Shell.

1. Launch the [Cloud Shell](https://shell.azure.com/). For details, [read more about PowerShell in Cloud Shell](https://aka.ms/pscloudshell/docs).

1. Connect to Azure AD. You must specify `<tenant_id>` if you have access to more than one AAD tenants.

    ```console
   Connect-AzureAD -TenantID <tenant_id>
    ```

1. Upload the script to your cloud shell using the following command:

    ```console
    curl https://raw.githubusercontent.com/microsoft/sql-server-samples/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-license-type.ps1
    ```

1. Execute the command as shown by the examples.

> [!NOTE]
> - To paste the commands into the shell, use `Ctrl-Shift-V` on Windows or `Cmd-v` on MacOS.
> - The script will be uploaded directly to the home folder associated with your Cloud Shell session.

# Schedule the script execution using Azure Runbook

You can schedule the command to run as a runbook. Follow these steps using the Azure Portal:

### 1. Download the Script

Open a command shell on your device and  dowload the script to to your current folder.

```console
curl https://raw.githubusercontent.com/microsoft/sql-server-samples/refs/heads/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-license-type.ps1
```
### 2. Create or Use an Existing Automation Account
[Create a new automation account](https://ms.portal.azure.com/#create/Microsoft.AutomationAccount)  or open an existing one. In the Advanced section, ensure that System assigned identity is selected.

### 3. Import the Runbook
- Navigate to the Process Automation group and select **Runbooks**.

- Click on the **Import a runbook** tab and configure it:

    **File**: Select the file you downloaded in Step 1.  
    **Name**: Enter a name for the runbook.  
    **Type**: Set to PowerShell.  
    **Runtime Version**: Choose 7.2.

- Click **Import**.

### 4. Publish the Runbook
After the runbook is imported, click the **Publish** button to make it available for scheduling.

### 5. Link the Runbook to a Schedule

- Once the runbook status is *Published*, click on the **Link to schedule** button.  
- Select *Link a schedule to your runbook* and click **+ Add**.
- Configure the schedule:  
    **Name**: Provide a name for the schedule.  
    **Start Time**: Set the desired start time.  
    **Recurrence**: Choose the recurrence need it.  
- Click **Create**.

### 6. Configure Runbook Parameters
- Return to the **Schedule runbook** page.
- Click on **Parameters** and run settings.
- Paste the license type value into the appropriate field.
- Click **OK** to link the schedule, then **OK** again to create the job.

### 7. Verify the Runbook Execution
On the runbook Overview page:
- Open a recent job that was completed after the scheduled start time.
- Click on the **Output tab** and verify that you see:  `Properties.activationState=Activated  `

Your license is now active.

For more information about the runbooks, see the [Runbook tutorial](https://docs.microsoft.com/en-us/azure/automation/learn/automation-tutorial-runbook-textual-powershell)