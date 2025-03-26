---
services: Azure SQL
platforms: Azure
author: anosov1960
ms.author: sashan
ms.date: 03/25/2025
---


# Overview

This script provides a scaleable solution to set or change the license type on all Azure SQL Servers resources in a specified scope.

You can specify a single subscription to scan, or provide a list of subscriptions as a .CSV file.
If not specified, all subscriptions your role has access to are scanned.

# Prerequisites

- The following minimum RBAC premissions are required to set the licesne type on the individual Azure SQL resources:
1. **Azure SQL Databases**: *SQL DB Contributor role*. 
1. **Azure SQL Elastic Pools**: *SQL DB Contributor*
1. **Azure SQL Managed Instances**: *SQL Managed Instance Contributor*
1. **Azure SQL Instance Pools**: *SQL Managed Instance Contributor*
1. **Azure Data Factory SSIS Integration Runtimes**: *Data Factory Contributor role*.
1. **SQL Servers in Azure Virtual Machines**: *Virtual Machine Contributor role*. 

A *Subscriptin Contributor* role has sufficient permissions to mdify any of the above resources. 

# Launching the script

The script accepts the following command line parameters:

| **Parameter** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;  | **Value** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; | **Description** |
|:--|:--|:--|
|-SubId|subscription_id *or* a file_name|Optional: Subscription id or a .csv file with the list of subscriptions<sup>1</sup>. If not specified all subscriptions will be scanned|
|-ResourceGroup |resource_group_name|Optional: Limits the scope  to a specific resource group|
|-LicenseType | "LicenseIncluded" or "BasePrice"| Optional: Sets the license type to the specified value. If not specified, "LicenseIncluded" is set  |

<sup>1</sup>You can create a .csv file using the following command and then edit to remove the subscriptions you don't  want to scan.
```PowerShell
Get-AzSubscription | Export-Csv .\mysubscriptions.csv -NoTypeInformation
```

## Example 1

The following command will scan all the subscriptions to which the user has access to, and set the license type to "LicenseIncluded" on all servers where license type is undefined.

```PowerShell
.\modify-license-type.ps1 -LicenseType LicenseIncluded
```

## Example 2

The following command will scan the subscription `<sub_id>` and set the license type value to "LicenseIncluded" on all servers.

```PowerShell
.\modify-license-type.ps1 -SubId <sub_id> -LicenseType LicenseIncluded```

## Example 3

The following command will scan resource group `<resource_group_name>` in the subscription `<sub_id>`, set the license type value to "BasePrice".

```PowerShell
.\modify-license-type.ps1 -SubId <sub_id> -ResourceGroup <resource_group_name> -LicenseType BasePrice
```

# Running the script using Cloud Shell

This option is recommended because Cloud shell has the Azure PowerShell modules pre-installed and you are automatically authenticated.  Use the following steps to run the script in Cloud Shell.

1. Launch the [Cloud Shell](https://shell.azure.com/). For details, [read more about PowerShell in Cloud Shell](https://aka.ms/pscloudshell/docs).

1. Connect to Azure AD. You must specify `<tenant_id>` if you have access to more than one AAD tenants.

    ```console
   Connect-AzureAD -TenantID <tenant_id>
    ```

1. Upload the script to your cloud shell using the following command:

    ```console
    curl https://raw.githubusercontent.com/microsoft/sql-server-samples/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-license-type.ps1 -o modify-license-type.ps1
    ```

1. Run the script.

> [!NOTE]
> - To paste the commands into the shell, use `Ctrl-Shift-V` on Windows or `Cmd-v` on MacOS.
> - The script will be uploaded directly to the home folder associated with your Cloud Shell session.

# Running the script from a PC

Use the following steps to run the script in a PowerShell session on your PC.

1. Copy the script to your current folder:

    ```console
    curl https://raw.githubusercontent.com/microsoft/sql-server-samples/master/samples/manage/azure-hybrid-benefit/modify-license-type/modify-license-type.ps1 -o modify-license-type.ps1
    ```

1. Make sure the NuGet package provider is installed:

    ```console
    Set-ExecutionPolicy  -ExecutionPolicy RemoteSigned -Scope CurrentUser
    Install-packageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
    ```

1. Make sure the the Az module is installed. For more information, see [Install the Azure Az PowerShell module](https://learn.microsoft.com/powershell/azure/install-az-ps):

    ```console
    Install-Module Az -Scope CurrentUser -Repository PSGallery -Force
    ```

1. Connect to Azure AD and log in to your Azure account. You must specify `<tenant_id>` if you have access to more than one AAD tenants.

    ```console
    Connect-AzureAD -TenantID <tenant_id>
    Connect-AzAccount -TenantID (Get-AzureADTenantDetail).ObjectId
    ```

1. Run the script. 
