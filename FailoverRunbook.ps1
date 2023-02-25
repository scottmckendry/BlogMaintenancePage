# FailoverRunbook.ps1
# Scott McKendry - Feburary 2023
#----------------------------------------------------------------
# Checks domains to see if up, failing over to the SWA if it is down.
# Runs after failover check for a given expected outage period and revert the changes after that period completes.

# Retrieve Azure Automation Account Credentials
$cloudflareCredentials = Get-AutomationPSCredential -Name "AAC-Cloudflare"
$domainsCredentials = Get-AutomationPSCredential -Name "AAC-Domains" # Username is treated like CSV row (no spaces allowed)
$failoverUrlsCredentials = Get-AutomationPSCredential -Name "AAC-FailoverUrls" # Username is treated like CSV row (no spaces allowed)
$zonesAndIpCredentials = Get-AutomationPSCredential -Name "AAC-ZonesAndIP" # Username is treated like CSV row (no spaces allowed)

# Variables (domains, failoverUrls and zones must all be in same order)
$revertAfterMins = 29
$cloudflareEmail = $cloudflareCredentials.Username
$cloudflareApiKey = $cloudflareCredentials.GetNetworkCredential().Password
$domains = $domainsCredentials.Username.Split(",")
$failoverUrls = $failoverUrlsCredentials.Username.Split(",")
$zones = $zonesAndIpCredentials.Username.Split(",")
$ip = $zonesAndIpCredentials.GetNetworkCredential().Password

# Cloudflare API Headers
$headers = @{
    "X-Auth-Email" = $cloudflareEmail
    "X-Auth-Key"   = $cloudflareApiKey
}

$domainIndex = 0
foreach ($domain in $domains) {

    # Get domain specific info
    $failover = $failoverUrls[$domainIndex]
    $zone = $zones[$domainIndex]

    # Get A record from the cloudflare
    $requestUrl = "https://api.cloudflare.com/client/v4/zones/$($zone)/dns_records/?name=$($domain)&type=A"
    $recordToCheck = Invoke-RestMethod -Uri $requestUrl -Method Get -Headers $headers
    $recordId = $recordToCheck.result.id

    # A Record exists, check to see if the site is up
    if ($recordId) {
        $targetUrl = "https://$($domain)"
        $websiteResponse = Invoke-WebRequest -uri $targetUrl -SkipHttpErrorCheck
        $returnCode = $websiteResponse.StatusCode

        if ($returnCode -eq 200) {
            Write-Host "$domain is up."
        }
        else {
            # Delete A record
            $requestUrl = "https://api.cloudflare.com/client/v4/zones/$($zone)/dns_records/$recordId"
            Invoke-WebRequest -Uri $requestUrl -Method Delete -Headers $headers | Out-Null
        
            # Create CNAME record
            $newCnameRecord = @{
                "type"    = "CNAME"
                "name"    = "@"
                "content" = $failover
                "proxied" = $true
            }
            $body = $newCnameRecord | ConvertTo-Json
            $requestUrl = "https://api.cloudflare.com/client/v4/zones/$($zone)/dns_records"
            Invoke-WebRequest -Uri $requestUrl -Method Post -Headers $headers -Body $body -ContentType "application/json" | Out-Null
            Write-Host "$domain is down. Failed over to SWA."
        }
    }

    # No A record == Failed Over in a previous run
    else {
        # Get the CNAME record
        $requestUrl = "https://api.cloudflare.com/client/v4/zones/$($zone)/dns_records/?name=$($domain)&type=CNAME"
        $recordToCheck = Invoke-RestMethod -Uri $requestUrl -Method Get -Headers $headers
        $recordId = $recordToCheck.result.id

        # Get offset of created time vs current time
        $recordCreatedTime = $recordToCheck.Result.created_on
        $currentTime = Get-Date -AsUtc
        $offset = $currentTime - $recordCreatedTime

        # If created longer than revertAfter, revert changes
        if ($offset.TotalMinutes -gt $revertAfterMins) {
            # Delete CNAME record
            $requestUrl = "https://api.cloudflare.com/client/v4/zones/$($zone)/dns_records/$recordId"
            Invoke-WebRequest -Uri $requestUrl -Method Delete -Headers $headers | Out-Null
         
            # Create A record
            $newCnameRecord = @{
                "type"    = "A"
                "name"    = "@"
                "content" = $ip
                "proxied" = $true
            }
            $body = $newCnameRecord | ConvertTo-Json
            $requestUrl = "https://api.cloudflare.com/client/v4/zones/$($zone)/dns_records"
            Invoke-WebRequest -Uri $requestUrl -Method Post -Headers $headers -Body $body -ContentType "application/json" | Out-Null
            Write-Host "$domain expected outage time complete. Reverting DNS Changes"
        }
        else {
            Write-Host "$domain within expected outage time. No change to DNS."
        }
    }
    $domainIndex++
}