# Paygo-SQLMI 

This Azure Policy ensures that all SQL Managed Instance resources using `LicenseType = BasePrice` are marked as non-compliant. The remediation task sets `LicenseType = LicenseIncluded`.

Use Azure CLI or PowerShell to create the policy definition:

## Artifacts

- **policy.json**: Main policy definition referencing external parameter and rule files.
- **params.json**: Defines policy parameters.
- **rules.json**: Contains the policy rule logic.

## Create policy
Use the following command to create policy

```bash

#!/bin/bash

az policy definition create \
  --name "Paygo-SQLMI" \
  --display-name "Paygo-SQLMI" \
  --description "This Azure Policy ensures that all SQL Managed Instance resources using LicenseType = BasePrice are marked as non-compliant. The remediation task sets LicenseType = LicenseIncluded." \
  --rules @rules.json \
  --params @params.json \
  --mode Indexed \
  --subscription "<your-subscription-id>"\
```

## Assign policy

Use the following command to assign policy

```bash
#!/bin/bash

# Set variables
SUB_ID="<your-subscription-id>"
RG_NAME="<your-resoure-group>" # optional
SCOPE="/subscriptions/$SUB_ID/resourceGroups/$RG_NAME"
LOCATION="<your-azure-region>"

# Create policy assignment
az policy assignment create \
  --name "Paygo-SQLMI-Assign" \
  --policy "Paygo-SQLMI" \
  --scope "$SCOPE" \
  --params '{ "effect": { "value": "DeployIfNotExists" } }' \
  --mi-system-assigned \
  --role "Contributor" \
  --identity-scope "$SCOPE" \
  --location "$LOCATION"
```

## Create remediation task

Us the following command to create a remediation task

```bash
#!/bin/bash

RG_NAME="<your-resoure-group>"

az policy remediation create \
  --name "Remediate-Paygo-SQLMI" \
  --policy-assignment "Paygo-SQLMI-Assign" \
  --resource-group "$RG_NAME" \
  --resource-discovery-mode ReEvaluateCompliance
```
