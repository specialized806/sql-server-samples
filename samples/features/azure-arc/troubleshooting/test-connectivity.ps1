#This script repeatedly probes all regions for connectivity to the Azure Arc data services/Arc-enabled SQL Server endpoints for telemetry and the data processing service.
#The script will output the status of the connectivity to the console.
#The script will run indefinitely until stopped by the user.
#The script will iterate through all regions in the $regions array.
#The list of regions are updated as of June 7,2024 to reflect all publicly available, supported Azure regions for Arc-enabled SQL Server.

$regions = @(
    "East US",
    "East US 2",
    "West US 2",
    "West US 3",
    "Central US",
    "North Central US",
    "South Central US",
    "West Central US",
    "Canada Central",
    "Canada East",
    "UK South",
    "UK West",
    "France Central",
    "West Europe",
    "North Europe",
    "Switzerland North",
    "Central India",
    "Brazil South",
    "South Africa North",
    "UAE North",
    "Japan East",
    "Korea Central",
    "Southeast Asia",
    "Australia East",
    "Sweden Central",
    "Norway East"
)

$regions = $regions | ForEach-Object { $_.Replace(" ", "") }

do{
    $regions | ForEach-Object {
        $dps_url =  "dataprocessingservice.$_.arcdataservices.com"
        $ti_url =  "telemetry.$_.arcdataservices.com"
        try{
            $dps_result = (Invoke-WebRequest -Uri $dps_url -Method Get).StatusCode
        }catch{
            $dps_result = $_.Exception.Message
        }
        try{
            $ti_result = (Invoke-WebRequest -Uri $ti_url -Method Get).StatusCode
            if($ti_result -contains "401"){  #As of now, the telemetry endpoint returns unauthorized status code if accessing in an unauthenticated way. Since this is a connectivity test script, a 401 response is good enough to establish availability and connectivity.
                $ti_result = "Expected"
            }
        }catch{
            if($_.Exception.Message -like "*401*"){
                $ti_result = "Expected"
            }
            else {
                $ti_result = $_.Exception.Message
            }
            
        }
        Write-Host $dps_result $ti_result " :: $_"
    }
    Write-Host "============================================"
} while($true)
