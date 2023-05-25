<#
    .DESCRIPTION
        A powershell to query the Azure Management API to get the current usage and limits for a subscription
        Ideally run from a runbook and monitored with Azure Monitor

    .NOTES
        AUTHOR: Chad Voelker
        REQUIREMENTS: Microsoft.Capacity resource provider enabled in the subscription
        REFERENCES: 
            Create a runbook: https://learn.microsoft.com/en-us/azure/automation/manage-runbooks
            APIs: 
                Usage: https://learn.microsoft.com/en-us/rest/api/quota/usages/list?tabs=HTTP
                Quotas: https://learn.microsoft.com/en-us/rest/api/quota/quota/list?tabs=HTTP
            List of Resource Providers: https://learn.microsoft.com/en-us/rest/api/resources/providers/list?tabs=HTTP
        WARRANTY: None expressed or implied.  Use at your own risk.
        EXAMPLE OUTPUT (showing anything over 1%):
            WARNING: NEARING OR ABOVE LIMIT: 'Storage Accounts' Usage: 6, Quota: 250, Percentage: 2.4%      
            [Provider: Microsoft.Storage Region: eastus] 1 out of 1 are nearing limit
            [Provider: Microsoft.Storage Region: centralus] 0 out of 1 are nearing limit
            [Provider: Microsoft.Storage Region: eastus2] 0 out of 1 are nearing limit
            WARNING: NEARING OR ABOVE LIMIT: 'Network Watchers' Usage: 1, Quota: 1, Percentage: 100%        
            [Provider: Microsoft.Network Region: eastus] 1 out of 54 are nearing limit
            [Provider: Microsoft.Network Region: centralus] 0 out of 54 are nearing limit                   
            WARNING: NEARING OR ABOVE LIMIT: 'Network Watchers' Usage: 1, Quota: 1, Percentage: 100%        
            [Provider: Microsoft.Network Region: eastus2] 1 out of 54 are nearing limit
            [Provider: Microsoft.Compute Region: eastus] 0 out of 141 are nearing limit                     
            [Provider: Microsoft.Compute Region: centralus] 0 out of 141 are nearing limit                  
            WARNING: NEARING OR ABOVE LIMIT: 'Total Regional vCPUs' Usage: 2, Quota: 100, Percentage: 2%    
            WARNING: NEARING OR ABOVE LIMIT: 'Standard DASv4 Family vCPUs' Usage: 2, Quota: 50, Percentage: 4%

    .PARAMETER subscriptionIds
        The subscription(s) to query
    .PARAMETER quotaPercentageToReport
        The percentage of quota to report. (Es a whole number, example / default: 80 = 80%)
    .PARAMETER regions
        The regions to query (Default: eastus, centralus, eastus2)
    .PARAMETER providers
        The providers to query (Default: Microsoft.Storage, Microsoft.Network, Microsoft.Compute)
#>

param(
    [Parameter(Mandatory=$true)]
    [string[]]$subscriptionIds,
    [Parameter(Mandatory=$false)]
    [string]$quotaPercentageToReport=80,
    [Parameter(Mandatory=$false)]
    [string[]]$regions = @("eastus", "centralus", "eastus2"),
    [Parameter(Mandatory=$false)]
    [string[]]$providers = @("Microsoft.Storage", "Microsoft.Network", "Microsoft.Compute")
)
    
foreach ($subscriptionId in $subscriptionIds) {
    try
    {
        "Logging in to Azure..."
        Connect-AzAccount -Subscription $subscriptionId
    }
    catch {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }    

    $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"

    foreach ($provider in $providers) {
        foreach ($region in $regions) {
            $usageUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/$provider/locations/$region/providers/Microsoft.Quota/usages?api-version=2021-03-15-preview"

#            Write-Host "Usage: $usageUri"
            $usageResponse = Invoke-WebRequest -URI $usageUri -Method Get -Headers @{Authorization = "Bearer $($token.Token)"}
            if ($usageResponse.StatusCode -ne 200) {
                Write-Error -Message "Error: $($usageResponse.StatusCode) $($usageResponse.StatusDescription)"
                throw "Error: $($usageResponse.StatusCode) $($usageResponse.StatusDescription)"
            }

            $quotaUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/$provider/locations/$region/providers/Microsoft.Quota/quotas?api-version=2021-03-15-preview"
#            Write-Host "Quota: $quotaUri"

            $quotaResponse = Invoke-WebRequest -URI $quotaUri -Method Get -Headers @{Authorization = "Bearer $($token.Token)"}
            if ($quotaResponse.StatusCode -ne 200) {
                Write-Error -Message "Error: $($quotaResponse.StatusCode) $($quotaResponse.StatusDescription)"
                throw "Error: $($quotaResponse.StatusCode) $($quotaResponse.StatusDescription)"
            }

            $usages = $usageResponse.content | ConvertFrom-Json
            $quotas = $quotaResponse.content | ConvertFrom-Json
            
            $totalUsageElements = $usages.value.count
            $totalQuotaElements = $quotas.value.count

            if($totalUsageElements -ne $totalQuotaElements)
            {
                Write-Warning "Usage ($totalUsageElements) and Quota ($totalQuotaElements) counts do no match"
            }

            $nearingLimit = 0
            foreach ($u in $usages.value) {
                $name = $u.properties.name.localizedValue

                $q = $quotas.value | Where-Object { $_.properties.name.localizedValue -eq $name }

                if($null -eq $q)
                {
                    Write-Warning "Corresponding quota not found for usage '$name'"
                    continue
                }

                $usageVal = $u.properties.usages.value
                $quotaVal = $q.properties.limit.value
                $percentage = $usageVal -gt 0 ? ($usageVal / $quotaVal * 100) : 0

                if ($percentage -gt $quotaPercentageToReport) {
                    $nearingLimit++
                    Write-Warning "NEARING OR ABOVE LIMIT: '$name' Usage: $usageVal, Quota: $quotaVal, Percentage: $percentage%"
                }
            }
    
            Write-Host "[Provider: $provider Region: $region] $nearingLimit out of $totalUsageElements are nearing limit"
        }
    }
}