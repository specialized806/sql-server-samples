# Overview

This script installs a pay-as-you-go SQL Server instance on your machine and automatically connext it to Azure Arc using a downloaded SQL Server media.

# Prerequisites

- You have met the [onboarding prerequisites](https://learn.microsoft.com/sql/sql-server/azure-arc/prerequisites).
- You have downloded a SQL Server image file from the workspace provided by Microsoft technical support. Tpo obtain it, open a support request using "Get SQL Installation Media" subcategory and soecify the desired version and edition. 
- You are a local admin on the machine where you run the script. 
- Your n
- If you are using a machine running Windows Server 2016, you have completed the mitigation steps as described below.


# Mitigating the TLS version issue on Windows Server 2016

When running the script on Windows Server 2016, the OS may be configured with a TLS version that does not meet the Azure security requirements. You need to enable strong TLS versions (TLS 1.2 and 1.3) when they are available, while still supporting older TLS versions (1.0 and 1.1) when TLS 1.2 and 1.3 are unavailable. You need to also disable versions SSL2 and SSL3, which are insecure.

To see if you need to make the change, run the command below from an elevated PowerShell prompt.
```PowerShell
[Net.ServicePointManager]::SecurityProtocol
```

If the result is `SSL3, Tls`, you need to fix the TLS version using one of the following  options.

__Option 1__: run the following command below from an elevated PowerShell prompt:
```PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls13
```

__Option 2__: run these two commands from an elevated PowerShell prompt:

```PowerShell
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NetFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord 
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NetFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord 
```

After running either of these command options, close and reopen PowerShell or reboot the machine (in case currently-running applications were referencing previous values). To verify that the changes were applied correctly, run this command again: 
```PowerShell
[Net.ServicePointManager]::SecurityProtocol
```
The result should be `Tls, Tls11, Tls12, Tls13`

# Launching the script

The script must be launched from and elevated PowerShell prompt. It accepts the following command line parameters:

| **Parameter** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;  | **Value** &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp;&nbsp; &nbsp; &nbsp; &nbsp; | **Description** |
|:--|:--|:--|
|-AzureSubscriptionId|subscription_id|Required: Subscription id that will contain the Arc-enabled machime and Arc-enable SQL Server resources. That subscription will be billed for SQL Server software using a pay-as-you-go method. |
|-AzureResourceGroup |resource_group_name|Required: Resource group that will contain the Arc-enabled machime and Arc-enable SQL Server resource.|
|-AzureRegion |region name| Required: the region to store the machuine and SQL Server meta-data. |
|-SqlServerInstanceName | name of the instance|Optional: the machine name will be used if not specified|
|-SqlServerAdminAccounts | SQL Server admin accounts | Optional. By default "BUILTIN\ADMINISTRATORS" will be used.|
|-SqlServerSvcAccount| SQL Server services account |Optional. By default "NT AUTHORITY\SYSTEM" will be used.|
|-SqlServerSvcPassword| SQL Server service account password| Required if a custom service account is specified.|
|-AgtServerSvcAccount|SQL Agent service account|Optional. By default "NT AUTHORITY\NETWORK SERVICE" will be used.|
|-AgtServerSvcPassword|SQL Agent service account pasdsword|Required if a custom service account is specified.|
|-IsoFolder|Folder path|Required. The folder contrainng the files downloaded from the workspace.|
|-Proxy|HTTP proxy URL|Optional. Needed if your networks is using a HTTP proxy.|

## Example

The following command installs a SQL Server instance from the folder `c:\downloads`, connect it to subscription ID `<sub_id>`, resource group `<resource_group>` in West US, and configure it with LicenseType=PAYG. It use the default admin and service accounts and direct connectivity to Azure.

```PowerShell
.\install-payg-sql-server.ps1 -AzureSubscriptionId <sub_id> -AzureResourceGroup <resource_group> -AzureRegion westus -IsoFolder c:\downloads
```
