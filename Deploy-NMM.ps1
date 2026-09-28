#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$AppServiceSku       = 'B2',
    [int]$AppServiceInstances    = 1,
    [string]$SqlEdition          = 'Standard',
    [string]$SqlServiceObjective = 'S1',
    [string[]]$Regions,
    [string]$Geography,
    [string]$SubscriptionId,
    [string]$OutFile,
    [switch]$RegisterProviders,
    [int]$ProviderTimeoutMinutes = 15
)

$ErrorActionPreference = 'Continue'

# The NMM post-install configuration script only runs in Azure Cloud Shell, so refuse to start anywhere else
$inCloudShell = $env:ACC_CLOUD -or
                ($env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*') -or
                ($env:POWERSHELL_DISTRIBUTION_CHANNEL -like 'CloudShell*')
if (-not $inCloudShell) {
    throw "This script must be run in Azure Cloud Shell (PowerShell). Open https://shell.azure.com and run it there."
}

$NmmRequiredProviders = @(
    'Microsoft.KeyVault','Microsoft.Compute','Microsoft.Automation','Microsoft.Storage',
    'Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.DesktopVirtualization',
    'Microsoft.Network','Microsoft.AAD','Microsoft.RecoveryServices','Microsoft.Web',
    'Microsoft.Quota','Microsoft.Solutions','Microsoft.Sql','Microsoft.MarketplaceOrdering'
)

# ====================================================================
#  Deployment Template for NMM
# ====================================================================

$nmmTemplateJson = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "sqlServerLogin": {
            "type": "string",
            "defaultValue": "sqladmin",
            "metadata": {
                "description": "SQL Server administrator login name"
            }
        },
        "sqlServerPassword": {
            "type": "securestring",
            "minLength": 8,
            "maxLength": 128,
            "metadata": {
                "description": "SQL Server administrator password. Must be 8-128 characters and contain at least: uppercase letters (A-Z), lowercase letters (a-z), digits (0-9), and special characters (!@#$%^&*)."
            }
        },
        "applicationResourceName": {
            "type": "string",
            "defaultValue": "nerdioMspApp"
        }
    },
    "variables": {},
    "resources": [
        {
            "type": "Microsoft.Solutions/applications",
            "apiVersion": "2021-07-01",
            "location": "[resourceGroup().Location]",
            "kind": "MarketPlace",
            "name": "[parameters('applicationResourceName')]",
            "plan": {
                "name": "nmm-plan",
                "product": "nmm",
                "publisher": "nerdio",
                "version": "6.8.0"
            },
            "properties": {
                "managedResourceGroupId": "[concat(subscription().id,'/resourceGroups/',take(concat(resourceGroup().name,'-',uniquestring(resourceGroup().id),uniquestring(parameters('applicationResourceName'))),90))]",
                "parameters": {
                    "location": {
                        "value": "[resourceGroup().location]"
                    },
                    "sqlServerLogin": {
                        "value": "[parameters('sqlServerLogin')]"
                    },
                    "sqlServerPassword": {
                        "value": "[parameters('sqlServerPassword')]"
                    }
                },
                "jitAccessPolicy": null
            }
        }
    ]
}
'@

# ====================================================================
#  Helper functions
# ====================================================================
function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function New-StrongPassword {
    param([int]$Length = 20)
    $sets  = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz', '0123456789', '!@#$%^&*'
    $all   = -join $sets
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[$rng::GetInt32($s.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[$rng::GetInt32($all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = $rng::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

function Invoke-ArmGet {
    # GET against ARM with retry on throttling (429), server errors (5xx) and dropped connections
    param([string]$Uri, [string]$Token, [int]$MaxAttempts = 4)
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-RestMethod -Method GET -Uri $Uri -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
        } catch {
            $status    = [int]$_.Exception.Response.StatusCode
            $retryable = ($status -eq 0) -or ($status -eq 429) -or ($status -ge 500)
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }
            $wait = [Math]::Pow(2, $attempt)
            $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta
            if ($retryAfter) { $wait = [Math]::Min(60, $retryAfter.TotalSeconds) }
            Start-Sleep -Seconds ([int][Math]::Ceiling($wait))
        }
    }
}

function Get-ProviderStates {
    $map  = @{}
    $list = az provider list --query "[].{ns:namespace, state:registrationState}" -o json --only-show-errors 2>$null | ConvertFrom-Json
    foreach ($p in $list) { $map[$p.ns] = $p.state }
    return $map
}

function Get-SqlRegionStatus {
    param(
        [string]$Region, [string]$Sub, [string]$Token,
        [string]$Edition, [string]$Slo, [string]$ApiVersion
    )
    $uri = "https://management.azure.com/subscriptions/$Sub/providers/Microsoft.Sql/locations/$Region/capabilities?api-version=$ApiVersion&include=supportedEditions"
    try {
        $resp = Invoke-ArmGet -Uri $uri -Token $Token
        $reason = $resp.supportedServerVersions.reason | Where-Object { $_ } | Select-Object -First 1
        if ($reason) { $reason = ($reason -replace '\s+', ' ').Trim() }

        $sloListed = $false
        foreach ($sv in $resp.supportedServerVersions) {
            foreach ($e in $sv.supportedEditions) {
                if ($e.name -eq $Edition) {
                    foreach ($o in $e.supportedServiceLevelObjectives) {
                        if ($o.name -eq $Slo) { $sloListed = $true }
                    }
                }
            }
        }

        if ($reason)       { return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = $reason } }
        elseif ($sloListed){ return [pscustomobject]@{ Region = $Region; Ok = $true;  Reason = '' } }
        else               { return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "$Edition/$Slo is not offered in this region" } }
    } catch {
        return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "SQL capabilities API error: $($_.Exception.Message)" }
    }
}

function Get-AppServiceQuotaStatus {
    param(
        [string]$Region, [string]$Sub, [string]$Token,
        [string]$Sku = 'B2',            # e.g. B1, B2, S1, P0v4, P1v3
        [int]$Required = 1,             # instances the deployment needs
        [string]$ApiVersion = '2025-03-01'
    )
    if ($Required -lt 1) { $Required = 1 }   # never allow a 0-instance check to pass a 0 limit
    $scope   ="https://management.azure.com/subscriptions/$Sub/providers/Microsoft.Web/locations/$Region/providers/Microsoft.Quota"

    $out = [pscustomobject]@{
        Region = $Region; Ok = $false; Reason = ''
        SkuUsed = $null; SkuLimit = $null; TotalUsed = $null; TotalLimit = $null
        SkuRowName = ''; SkuRowCount = 0
        NeedsQuota = $false   # quota row exists but limit is too low -> fixable with a quota increase
    }

    # Follows nextLink so large result sets aren't truncated
    function Get-All([string]$uri) {
        $items = @()
        while ($uri) {
            $r = Invoke-ArmGet -Uri $uri -Token $Token
            $items += @($r.value)
            $uri = $r.nextLink
        }
        return ,$items
    }

    # Returns ALL rows matching the API name or the portal display name ("B2 VMs")
    function Find-Rows($rows, [string]$pattern) {
        @($rows | Where-Object {
            $_.properties.name.value -match $pattern -or $_.properties.name.localizedValue -match $pattern
        })
    }

    try {
        $quotas = Get-All "$scope/quotas?api-version=$ApiVersion"
        $usages = Get-All "$scope/usages?api-version=$ApiVersion"
    } catch {
        $code = $null
        try { $code = ($_.ErrorDetails.Message | ConvertFrom-Json).error.code } catch {}
        $msg = if ($code) { "$code - $($_.Exception.Message)" } else { $_.Exception.Message }
        $out.Reason = "Quota API error: $msg"
        return $out
    }

    if (@($quotas).Count -eq 0) {
        $out.Reason = "No App Service quota data returned for this subscription/region"
        return $out
    }

    $checks = @(
        @{ Key = 'Sku';   Label = "$Sku VMs";           Pattern = "^$([regex]::Escape($Sku))(\s*VMs)?$" },
        @{ Key = 'Total'; Label = 'Total Regional VMs'; Pattern = 'Total\s*Regional' }
    )

    foreach ($chk in $checks) {
        $qHits = Find-Rows $quotas $chk.Pattern
        if ($chk.Key -eq 'Sku') {
            $out.SkuRowCount = $qHits.Count
            $out.SkuRowName  = (@($qHits | ForEach-Object { $_.properties.name.value }) -join ',')
        }
        if ($qHits.Count -eq 0) {
            # Total Regional VMs is informational; a missing row is not a blocker
            if ($chk.Key -eq 'Total') { continue }
            # Total Regional VMs can be listed while the SKU row is missing -> effective SKU limit is 0
            $out.Reason = "No '$($chk.Label)' quota row in this subscription/region (effective limit 0; request via support)"
            return $out
        }

        # Fail closed: a missing limit counts as 0, and with several matching rows use the smallest limit
        $limits = @($qHits | ForEach-Object {
            $v = $_.properties.limit.value
            if ($null -eq $v -or "$v" -eq '') { 0 } else { [int]$v }
        })
        $limit = ($limits | Measure-Object -Minimum).Minimum

        $uHits = Find-Rows $usages $chk.Pattern
        $used  = if ($uHits.Count -gt 0) {
            # The usages API reports -1 when there is no usage to report (seen on 0-limit SKUs), so clamp to 0
            ($uHits | ForEach-Object { $v = $_.properties.usages.value; if ($null -eq $v) { 0 } else { [Math]::Max(0, [int]$v) } } |
                Measure-Object -Maximum).Maximum
        } else { 0 }

        if ($chk.Key -eq 'Sku') { $out.SkuUsed = $used;   $out.SkuLimit = $limit }
        else                    { $out.TotalUsed = $used; $out.TotalLimit = $limit }

        # Total Regional VMs is informational: Azure shows it as 0/0 in regions where it isn't populated
        # (e.g. West US with B2 0/31), and it rises automatically when SKU quota is granted. Only treat it
        # as a blocker when it has a real limit that is exhausted; raising the SKU quota fixes that case too.
        if ($chk.Key -eq 'Total' -and $limit -eq 0) { continue }

        if ($limit -lt $Required -or ($limit - $used) -lt $Required) {
            $out.Reason     = "$($chk.Label): $used of $limit used, need $Required free (quota increase needed)"
            $out.NeedsQuota = $true
            return $out
        }
    }

    $out.Ok = $true
    return $out
}

function Request-AppServiceQuotaIncrease {
    # Raises the App Service SKU quota in one region through the Microsoft.Quota API.
    # Uses Invoke-AzRestMethod (signed-in Az PowerShell context) because it exposes the 202
    # response headers needed to track the async operation on both PowerShell 5.1 and 7.
    param(
        [string]$Region, [string]$Sub, [string]$Sku,
        [int]$NewLimit,
        [string]$ApiVersion = '2025-03-01',
        [int]$TimeoutMinutes = 10
    )
    $terminal = 'Succeeded','Failed','Invalid','Cancelled','Canceled'
    $path     = "/subscriptions/$Sub/providers/Microsoft.Web/locations/$Region/providers/Microsoft.Quota/quotas/$Sku`?api-version=$ApiVersion"

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Ok = $false; Limit = $null; Message = "No Az PowerShell context. Run Connect-AzAccount and retry." }
    }

    $body = @{
        properties = @{
            limit = @{ limitObjectType = 'LimitValue'; value = $NewLimit }
            name  = @{ value = $Sku }
        }
    } | ConvertTo-Json -Depth 5

    # 1. Submit the request
    try {
        $put = Invoke-AzRestMethod -Method PUT -Path $path -Payload $body -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Limit = $null; Message = "Quota request call failed: $($_.Exception.Message)" }
    }
    Write-Host ("    PUT status: {0}" -f $put.StatusCode)

    if ($put.StatusCode -notin 200, 201, 202) {
        return [pscustomobject]@{ Ok = $false; Limit = $null; Message = "Quota request rejected (HTTP $($put.StatusCode)): $($put.Content)" }
    }

    # 2. Poll the async operation until it reaches a terminal state
    $opState = 'Succeeded'; $opError = ''
    if ($put.StatusCode -eq 202) {
        $statusUrl = $null
        foreach ($h in 'Location', 'Azure-AsyncOperation') {
            if (-not $statusUrl) { try { $statusUrl = @($put.Headers.GetValues($h))[0] } catch {} }
        }
        if (-not $statusUrl) {
            $opState = 'Unknown'; $opError = 'Azure returned 202 without a status URL'
        } else {
            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            do {
                Start-Sleep -Seconds 10
                $poll    = Invoke-AzRestMethod -Method GET -Uri $statusUrl
                $pj      = $poll.Content | ConvertFrom-Json
                $opState = if ($pj.properties.provisioningState) { $pj.properties.provisioningState }
                           elseif ($pj.status) { $pj.status } else { 'Unknown' }
                Write-Host ("    [{0:HH:mm:ss}] {1}" -f (Get-Date), $opState)
            } while ($opState -notin $terminal -and (Get-Date) -lt $deadline)

            if ($opState -notin $terminal) {
                $opError = "timed out after $TimeoutMinutes minutes"
            } elseif ($pj.error) {
                $opError = "$($pj.error.code) - $($pj.error.message)"
            }
        }
    }

    # 3. The quota itself is the source of truth: Azure has been seen to report
    #    'Failed' (ContactSupport) on an operation that still applied the new limit.
    $limit = $null
    $get   = Invoke-AzRestMethod -Method GET -Path $path
    if ($get.StatusCode -eq 200) { $limit = ($get.Content | ConvertFrom-Json).properties.limit.value }

    if ($null -ne $limit -and [int]$limit -ge $NewLimit) {
        $note = if ($opState -ne 'Succeeded') { "Operation reported '$opState' ($opError) but the limit is now $limit." } else { '' }
        return [pscustomobject]@{ Ok = $true; Limit = [int]$limit; Message = $note }
    }

    $why = if ($opError) { $opError } else { "operation state '$opState'" }
    return [pscustomobject]@{ Ok = $false; Limit = $limit; Message = "Quota request did not apply ($why). Current limit: $limit." }
}

function Resolve-Geography {
    param([string]$Token)
    switch -Regex (($Token -replace '\s', '').ToLower()) {
        '^(us|usa|unitedstates)$'              { return @('US') }
        '^canada$'                             { return @('Canada') }
        '^(northamerica|na)$'                  { return @('US','Canada','Mexico') }
        '^(europe|eu)$'                        { return @('Europe','UK') }
        '^(uk|unitedkingdom)$'                 { return @('UK') }
        '^(asiapacific|apac|asia)$'            { return @('Asia Pacific') }
        '^(middleeast|me)$'                    { return @('Middle East') }
        '^africa$'                             { return @('Africa') }
        '^(southamerica|latam|latinamerica)$'  { return @('South America') }
        '^(mexico|mx)$'                        { return @('Mexico') }
        '^all$'                                { return $null }
        default { throw "Unrecognized -Geography '$Token'." }
    }
}

$geoMenu = [ordered]@{
    'United States'                        = @('US')
    'Canada'                               = @('Canada')
    'North America (US + Canada + Mexico)' = @('US','Canada','Mexico')
    'Europe (incl. UK)'                    = @('Europe','UK')
    'United Kingdom'                       = @('UK')
    'Asia Pacific'                         = @('Asia Pacific')
    'Middle East'                          = @('Middle East')
    'Africa'                               = @('Africa')
    'South America'                        = @('South America')
    'All regions'                          = $null
}

function Show-GeographyPrompt {
    Write-Host ''
    Write-Host "Where is the partner / MSP located?" -ForegroundColor Cyan
    $labels = @($geoMenu.Keys)
    for ($n = 0; $n -lt $labels.Count; $n++) {
        Write-Host ("  {0,2}. {1}" -f ($n + 1), $labels[$n])
    }
    try { $pick = Read-Host "Enter choice [1]" -ErrorAction Stop }
    catch { return $null }
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $labels.Count) {
        Write-Host "Invalid choice; defaulting to United States." -ForegroundColor Yellow
        $idx = 1
    }
    return $geoMenu[$labels[$idx - 1]]
}

# ====================================================================
#  Pre-flight (az auth)
# ====================================================================
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Run in Cloud Shell or install the Azure CLI."
}

if (-not $SubscriptionId) {
    # --refresh pulls the live list instead of the CLI cache; --all includes non-Enabled subs so they're visible
    $allSubs     = @(az account list --refresh --all --only-show-errors 2>$null | ConvertFrom-Json)
    $enabledSubs = @($allSubs | Where-Object { $_.state -eq 'Enabled' })
    if ($enabledSubs.Count -eq 0) {
        throw "No enabled Azure subscriptions found for this account."
    }
    if ($allSubs.Count -eq 1) {
        $SubscriptionId = $enabledSubs[0].id
        Write-Host ("Using only available subscription: {0}" -f $enabledSubs[0].name) -ForegroundColor DarkGray
    } else {
        Write-Host ''
        Write-Host "Select an Azure subscription:" -ForegroundColor Cyan
        $defaultIdx = 0
        for ($i = 0; $i -lt $allSubs.Count; $i++) {
            $s      = $allSubs[$i]
            $marker = if ($s.isDefault) { ' (current)' } else { '' }
            if ($s.state -eq 'Enabled') {
                Write-Host ("  {0,2}. {1}  [{2}]{3}" -f ($i + 1), $s.name, $s.id, $marker)
                if ($s.isDefault -or $defaultIdx -eq 0) { $defaultIdx = $i + 1 }
            } else {
                Write-Host ("  {0,2}. {1}  [{2}]{3}  - {4}, can't be used" -f ($i + 1), $s.name, $s.id, $marker, $s.state) -ForegroundColor DarkGray
            }
        }
        do {
            $pick = Read-Host "Enter choice [$defaultIdx]"
            if ([string]::IsNullOrWhiteSpace($pick)) { $pick = "$defaultIdx" }
            $idx = 0
            $valid = [int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $allSubs.Count
            if (-not $valid) {
                Write-Host ("Invalid choice. Enter 1-{0}." -f $allSubs.Count) -ForegroundColor Yellow
            } elseif ($allSubs[$idx - 1].state -ne 'Enabled') {
                Write-Host ("That subscription is {0} and can't be used. Pick another." -f $allSubs[$idx - 1].state) -ForegroundColor Yellow
                $valid = $false
            }
        } while (-not $valid)
        $SubscriptionId = $allSubs[$idx - 1].id
        Write-Host ("Selected: {0}" -f $allSubs[$idx - 1].name) -ForegroundColor Green
    }
}

az account set --subscription $SubscriptionId --only-show-errors | Out-Null
$ctx = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($ctx.id -ne $SubscriptionId -and $ctx.name -ne $SubscriptionId) {
    throw "Azure CLI couldn't switch to subscription '$SubscriptionId' (still on '$($ctx.name)')."
}
$subId = $ctx.id

# The checks use Azure CLI but the deployment uses Az PowerShell, so both must point at the same subscription
$azCtx = Set-AzContext -SubscriptionId $subId -Tenant $ctx.tenantId -ErrorAction SilentlyContinue
if (-not $azCtx -or $azCtx.Subscription.Id -ne $subId) {
    throw "Az PowerShell couldn't switch to subscription '$($ctx.name)'. Run 'Connect-AzAccount -Tenant $($ctx.tenantId)' and re-run the script."
}

$token = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $token) { throw "Could not acquire Azure access token." }

Write-Banner "Nerdio Manager for MSP (NMM) - Pre-Install Readiness Check"
Write-Host ("Subscription : {0}" -f $ctx.name)
Write-Host ("Sub ID       : {0}" -f $ctx.id)
Write-Host ("Checking for : App Service '{0}' x{1} (quota)  +  Azure SQL '{2}/{3}'" -f $AppServiceSku, $AppServiceInstances, $SqlEdition, $SqlServiceObjective)
Write-Host ''

# ====================================================================
#  Resource group check
# ====================================================================
# NMM deploys into the resource group's region, so the RG must be new (created in the region picked later).
# A soft-deleted Key Vault left by an earlier install into an RG with the same name also blocks the deployment.
Write-Banner "Resource Group Check"
while ($true) {
    $ResourceGroupName = "$ResourceGroupName".Trim()
    if ($ResourceGroupName -notmatch '^[-\w\.\(\)]{1,90}$' -or $ResourceGroupName.EndsWith('.')) {
        Write-Host "'$ResourceGroupName' isn't a valid resource group name (1-90 letters, digits, - _ . ( ), can't end in a period)." -ForegroundColor Yellow
        $ResourceGroupName = Read-Host "Enter a new resource group name"
        continue
    }
    if (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue) {
        Write-Host "Resource group '$ResourceGroupName' already exists. NMM needs a new resource group." -ForegroundColor Yellow
        $ResourceGroupName = Read-Host "Enter a new resource group name"
        continue
    }
    $deletedVaults = @(az keyvault list-deleted --only-show-errors 2>$null | ConvertFrom-Json |
        Where-Object { $_.properties.vaultId -like "*/resourceGroups/$ResourceGroupName-*" })
    if ($deletedVaults.Count -gt 0) {
        Write-Host "Soft-deleted Key Vault(s) from an earlier NMM install into '$ResourceGroupName' will block this deployment:" -ForegroundColor Yellow
        foreach ($kv in $deletedVaults) {
            Write-Host ("  - {0}  ({1}, deleted {2})" -f $kv.name, $kv.properties.location, $kv.properties.deletionDate) -ForegroundColor Yellow
        }
        $ans = Read-Host "Purge them now? [Y/n, N = use a different resource group name]"
        if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^[Yy]') {
            $purgeFailed = $false
            foreach ($kv in $deletedVaults) {
                Write-Host ("  Purging {0} (can take a few minutes)..." -f $kv.name) -ForegroundColor Cyan
                az keyvault purge --name $kv.name --location $kv.properties.location --only-show-errors
                if ($LASTEXITCODE -ne 0) { $purgeFailed = $true }
            }
            if (-not $purgeFailed) {
                Write-Host "  Purged." -ForegroundColor Green
                break
            }
            Write-Host "  Purge failed (purge protection may be on). Use a different resource group name." -ForegroundColor Red
        }
        $ResourceGroupName = Read-Host "Enter a new resource group name"
        continue
    }
    break
}
Write-Host ("Resource group '{0}' will be created in the region you pick." -f $ResourceGroupName) -ForegroundColor Green

# ====================================================================
#  Phase 0: Permission check
# ====================================================================
Write-Banner "Phase 0: Permission Check"
$me = az ad signed-in-user show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $me) {
    Write-Warning "Could not retrieve signed-in user info -- permission check skipped."
} else {
    Write-Host ("Signed-in user : {0}  ({1})" -f $me.displayName, $me.userPrincipalName)
    Write-Host ''
    $ownerAssignments = az role assignment list `
        --assignee $me.id --role Owner --scope "/subscriptions/$($ctx.id)" `
        --include-groups --include-inherited --only-show-errors 2>$null | ConvertFrom-Json
    $isOwner = ($null -ne $ownerAssignments -and @($ownerAssignments).Count -gt 0)

    $isGA = $null; $gaNote = ''
    try {
        $GA_TEMPLATE_ID = '62e90394-69f5-4237-9190-012177145e10'
        $dirRoles = az rest --method GET `
            --url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole' `
            --only-show-errors 2>$null | ConvertFrom-Json
        if ($dirRoles -and $dirRoles.PSObject.Properties['value']) {
            $isGA = [bool]($dirRoles.value | Where-Object { $_.roleTemplateId -eq $GA_TEMPLATE_ID })
        } else { $gaNote = ' (no directory roles returned)' }
    } catch { $gaNote = ' (Graph API check failed)' }

    $ownerLabel = if ($isOwner) { 'PASS' } else { 'FAIL' }
    $gaLabel    = if ($null -eq $isGA) { "UNKNOWN$gaNote" } elseif ($isGA) { 'PASS' } else { 'FAIL' }
    $ownerColor = if ($isOwner) { 'Green' } else { 'Red' }
    $gaColor    = if ($null -eq $isGA) { 'Yellow' } elseif ($isGA) { 'Green' } else { 'Red' }
    "{0,-55} {1}" -f "  Subscription Owner", $ownerLabel | Write-Host -ForegroundColor $ownerColor
    if ($isOwner) {
        # Report how each Owner assignment reaches this user: direct, via group, and/or inherited
        $subScope = "/subscriptions/$($ctx.id)"
        foreach ($a in @($ownerAssignments)) {
            $via = if ($a.principalId -eq $me.id) { 'direct to user' }
                   else { "via $($a.principalType) '$($a.principalName)'" }
            $at  = if ($a.scope -eq $subScope) { 'on this subscription' }
                   elseif ($a.scope -eq '/') { 'inherited from tenant root (/)' }
                   elseif ($a.scope -match '/managementGroups/([^/]+)$') { "inherited from management group '$($Matches[1])'" }
                   else { "inherited from $($a.scope)" }
            Write-Host ("      - Owner {0}, {1}" -f $via, $at) -ForegroundColor DarkGray
        }
    }
    "{0,-55} {1}" -f "  Entra ID Global Administrator", $gaLabel | Write-Host -ForegroundColor $gaColor
    Write-Host ''

    if ((-not $isOwner) -or ($isGA -eq $false)) {
        Write-Host '  ACTION REQUIRED: Missing permissions will cause the NMM install to fail.' -ForegroundColor Red
        if (-not $isOwner)   { Write-Host ("  -> Assign Owner on subscription '{0}'." -f $ctx.name) -ForegroundColor Red }
        if ($isGA -eq $false){ Write-Host '  -> Assign Global Administrator in Entra ID.' -ForegroundColor Red }
        $cont = Read-Host "`nContinue anyway? [y/N]"
        if ($cont -notmatch '^[Yy]') {
            Write-Host "Exiting. Fix the permissions above and re-run." -ForegroundColor Red
            return
        }
    } else {
        Write-Host '  All required permissions confirmed.' -ForegroundColor Green
    }
}

# ====================================================================
#  Phase 1: Resource provider registration
# ====================================================================
Write-Banner "Phase 1: Resource Provider Registration"
$states = Get-ProviderStates
$providerResults = foreach ($ns in $NmmRequiredProviders) {
    [pscustomobject]@{ Provider = $ns; State = if ($states[$ns]) { $states[$ns] } else { 'UNKNOWN' } }
}
$providerResults | Format-Table -AutoSize | Out-Host

$unregistered = @($providerResults | Where-Object { $_.State -ne 'Registered' })
if ($unregistered.Count -eq 0) {
    Write-Host 'All required providers are Registered.' -ForegroundColor Green
} else {
    Write-Host ("{0} provider(s) are not registered:" -f $unregistered.Count) -ForegroundColor Yellow
    foreach ($p in $unregistered) {
        Write-Host ("  - {0}  ({1})" -f $p.Provider, $p.State) -ForegroundColor Yellow
    }

    if (-not $RegisterProviders) {
        $answer = Read-Host "`nRegister these providers now? [Y/n]"
        if (-not ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[Yy]')) {
            Write-Host "Cannot proceed without required providers. Exiting." -ForegroundColor Red
            return
        }
    }

    Write-Host ("Registering {0} provider(s)..." -f $unregistered.Count) -ForegroundColor Yellow
    foreach ($p in $unregistered) {
        Write-Host ("  {0}: registering..." -f $p.Provider) -ForegroundColor Yellow
        az provider register --namespace $p.Provider --output none --only-show-errors
    }
    Write-Host ("Polling (timeout: {0}m)..." -f $ProviderTimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($ProviderTimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $states  = Get-ProviderStates
        $pending = @($NmmRequiredProviders | Where-Object { $states[$_] -and $states[$_] -ne 'Registered' } |
            ForEach-Object { "$_ ($($states[$_]))" })
        if ($pending.Count -gt 0) { Write-Host ("  Pending: {0}" -f ($pending -join ', ')) }
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($pending.Count -gt 0) {
        Write-Warning "Some providers did not finish registering within $ProviderTimeoutMinutes minutes. Aborting."
        return
    }
    Write-Host 'All providers Registered.' -ForegroundColor Green
}

# ====================================================================
#  Phase 2: Region eligibility
# ====================================================================
Write-Banner "Phase 2: Region Eligibility"
Write-Host "Loading Azure region list..." -ForegroundColor DarkGray
$allLocations = az account list-locations --only-show-errors 2>$null | ConvertFrom-Json
$physical     = $allLocations | Where-Object { $_.metadata.regionType -eq 'Physical' }

$nameToSlug = @{}; $slugToName = @{}; $slugToGeo = @{}
foreach ($loc in $physical) {
    $nameToSlug[$loc.displayName] = $loc.name
    $slugToName[$loc.name]        = $loc.displayName
    $slugToGeo[$loc.name]         = $loc.metadata.geographyGroup
}

# Region discovery only: this lists where the SKU is OFFERED, not whether this
# subscription has quota for it. Quota is checked per region further below.
Write-Host ("Querying App Service regions that offer '{0}'..." -f $AppServiceSku) -ForegroundColor DarkGray
$appSvcRaw   = az appservice list-locations --sku $AppServiceSku --only-show-errors 2>$null | ConvertFrom-Json
$appSvcSlugs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $appSvcRaw) {
    $slug = if ($nameToSlug.ContainsKey($r.name)) { $nameToSlug[$r.name] } else { ($r.name -replace '\s','').ToLower() }
    [void]$appSvcSlugs.Add($slug)
}
Write-Host ("  -> {0} regions offer App Service {1}." -f $appSvcSlugs.Count, $AppServiceSku) -ForegroundColor DarkGray

# Region selection loop: the picker's option 0 returns here to choose a different geography
while ($true) {
    if ($Regions) {
        $candidates = $Regions | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
    } else {
        $geoGroups = $null
        $geoLabel  = 'All regions'
        if ($Geography) {
            $geoGroups = Resolve-Geography $Geography
            $geoLabel  = $Geography
        } elseif ([Environment]::UserInteractive) {
            $geoGroups = Show-GeographyPrompt
            $geoLabel  = if ($null -eq $geoGroups) { 'All regions' } else { ($geoGroups -join ', ') }
        }
        $candidates = @($appSvcSlugs)
        if ($null -ne $geoGroups) {
            $candidates = $candidates | Where-Object { $geoGroups -contains $slugToGeo[$_] }
        }
        $candidates = $candidates | Sort-Object
        Write-Host ("Checking {0} region(s) in '{1}'..." -f $candidates.Count, $geoLabel) -ForegroundColor DarkGray
    }

    if (-not $candidates -or @($candidates).Count -eq 0) {
        Write-Host "No candidate regions to check." -ForegroundColor Yellow
        $back = Read-Host "Go back and choose a different geography? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($back) -or $back -match '^[Yy]') { $Regions = $null; $Geography = $null; continue }
        return
    }

    $apiVersion      = '2023-05-01-preview'   # Microsoft.Sql capabilities
    $quotaApiVersion = '2025-03-01'           # Microsoft.Quota (App Service SKU quota)
    $candidates      = @($candidates)

    # SQL availability and App Service quota for a region run in the same parallel worker (one pass, not two)
    Write-Host ("Checking Azure SQL {0}/{1} availability and App Service {2} quota..." -f $SqlEdition, $SqlServiceObjective, $AppServiceSku) -ForegroundColor DarkGray
    $fnArm   = ${function:Invoke-ArmGet}.ToString()
    $fnSql   = ${function:Get-SqlRegionStatus}.ToString()
    $fnQuota = ${function:Get-AppServiceQuotaStatus}.ToString()
    $checkResults = $candidates | ForEach-Object -Parallel {
        ${function:Invoke-ArmGet}             = $using:fnArm
        ${function:Get-SqlRegionStatus}       = $using:fnSql
        ${function:Get-AppServiceQuotaStatus} = $using:fnQuota
        $sql = Get-SqlRegionStatus -Region $_ -Sub $using:subId -Token $using:token `
                   -Edition $using:SqlEdition -Slo $using:SqlServiceObjective -ApiVersion $using:apiVersion
        $app = Get-AppServiceQuotaStatus -Region $_ -Sub $using:subId -Token $using:token `
                   -Sku $using:AppServiceSku -Required $using:AppServiceInstances -ApiVersion $using:quotaApiVersion
        [pscustomobject]@{ Region = $_; Sql = $sql; App = $app }
    } -ThrottleLimit 15

    $sqlByRegion = @{}; $appByRegion = @{}
    foreach ($c in $checkResults) { $sqlByRegion[$c.Region] = $c.Sql; $appByRegion[$c.Region] = $c.App }
    $appResults = @($checkResults | ForEach-Object { $_.App })

    # If the Quota API failed in EVERY region, the problem is the API call itself
    # (unsupported scope, auth, registration), not the subscription's quota.
    $appQuotaResults = @($appResults | Where-Object { $_ })
    if ($appQuotaResults.Count -gt 0 -and
        @($appQuotaResults | Where-Object { $_.Reason -like 'Quota API error*' }).Count -eq $appQuotaResults.Count) {
        Write-Warning "App Service quota API failed in every region; quota could not be verified. First error: $($appQuotaResults[0].Reason)"
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($slug in $candidates) {
        $offered   = $appSvcSlugs.Contains($slug)
        $app       = $appByRegion[$slug]
        $appOk     = $offered -and ($null -ne $app) -and ($app.Ok -eq $true)
        $appQuota  = $offered -and ($null -ne $app) -and ($app.NeedsQuota -eq $true)
        $sql       = $sqlByRegion[$slug]
        $sqlOk     = ($null -ne $sql) -and ($sql.Ok -eq $true)
        $display   = if ($slugToName.ContainsKey($slug)) { $slugToName[$slug] } else { $slug }
        $appReason = if ($appOk) { '' }
                     elseif (-not $offered) { "App Service $AppServiceSku not offered" }
                     elseif ($app) { $app.Reason }
                     else { 'no App Service quota result' }
        $skuQuota   = '-'
        if ($app -and $null -ne $app.SkuLimit)   { $skuQuota   = '{0}/{1}' -f $app.SkuUsed, $app.SkuLimit }
        $totalQuota = '-'
        if ($app -and $null -ne $app.TotalLimit) { $totalQuota = '{0}/{1}' -f $app.TotalUsed, $app.TotalLimit }
        $results.Add([pscustomobject]@{
            Region           = $slug
            DisplayName      = $display
            AppService       = if ($appOk) { 'Yes' } elseif ($appQuota) { 'Quota' } else { 'No' }
            "${AppServiceSku}Quota" = $skuQuota
            SqlDb            = if ($sqlOk) { 'Yes' } else { 'No' }
            Eligible         = if ($appOk -and $sqlOk) { 'YES' } elseif ($appQuota -and $sqlOk) { 'QUOTA' } else { 'no' }
            SqlReason        = if ($sqlOk) { '' } else { if ($sql) { $sql.Reason } else { 'no SQL result' } }
            AppServiceReason = $appReason
            SkuRowName       = if ($app) { $app.SkuRowName } else { '' }
            SkuRowCount      = if ($app) { $app.SkuRowCount } else { 0 }
            TotalRegional    = $totalQuota
        })
    }

    $eligRank = @{ 'YES' = 0; 'QUOTA' = 1; 'no' = 2 }
    $sorted   = $results | Sort-Object @{E={ $eligRank[$_.Eligible] }}, DisplayName
    # Regions that only need a quota increase are still offered in the picker, with a warning
    $eligible = @($sorted | Where-Object { $_.Eligible -eq 'YES' -or $_.Eligible -eq 'QUOTA' })

    Write-Banner "Results"
    $sorted | Format-Table Region, DisplayName, AppService, "${AppServiceSku}Quota", SqlDb, Eligible -AutoSize | Out-Host

    $needQuota = @($sorted | Where-Object { $_.Eligible -eq 'QUOTA' })
    if ($needQuota.Count -gt 0) {
        Write-Host "Eligible after a quota increase (SKU quota row exists but limit is too low):" -ForegroundColor Yellow
        foreach ($r in $needQuota) {
            Write-Host ("  {0,-22} {1}" -f $r.Region, $r.AppServiceReason) -ForegroundColor Yellow
        }
        Write-Host ''
    }

    $ineligible = @($sorted | Where-Object { $_.Eligible -eq 'no' })
    if ($ineligible.Count -gt 0) {
        Write-Host "Why regions are not eligible:" -ForegroundColor DarkYellow
        foreach ($r in $ineligible) {
            $why = @($r.AppServiceReason, $r.SqlReason | Where-Object { $_ }) -join ' | '
            Write-Host ("  {0,-22} {1}" -f $r.Region, $why) -ForegroundColor DarkYellow
        }
        Write-Host ''
    }

    if ($OutFile) {
        $sorted | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
        Write-Host ("Results CSV: {0}" -f $OutFile) -ForegroundColor Cyan
    }

    if ($eligible.Count -eq 0) {
        Write-Host "No region has App Service $AppServiceSku (available or requestable) and SQL $SqlEdition/$SqlServiceObjective available." -ForegroundColor Red
        $back = Read-Host "Go back and choose a different geography? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($back) -or $back -match '^[Yy]') { $Regions = $null; $Geography = $null; continue }
        Write-Host "Exiting." -ForegroundColor Red
        return
    }

    # ====================================================================
    #  Phase 3: Region picker
    # ====================================================================
    Write-Banner "Select a region for NMM deployment"
    $quotaCol = "${AppServiceSku}Quota"
    for ($i = 0; $i -lt $eligible.Count; $i++) {
        $e = $eligible[$i]
        if ($e.Eligible -eq 'QUOTA') {
            Write-Host ("  {0,2}. {1}  ({2})  [needs {3} quota increase, currently {4} - the script will request it automatically in the next step]" -f ($i + 1), $e.DisplayName, $e.Region, $AppServiceSku, $e.$quotaCol) -ForegroundColor Yellow
        } else {
            Write-Host ("  {0,2}. {1}  ({2})" -f ($i + 1), $e.DisplayName, $e.Region)
        }
    }
    Write-Host ''
    Write-Host "   0. << Back to geography / region selection" -ForegroundColor Cyan

    $idx = -1
    do {
        $pick = Read-Host "`nEnter choice [1]"
        if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
        if ($pick -match '^[Bb]') { $pick = '0' }
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 0 -or $idx -gt $eligible.Count) {
            Write-Host ("Invalid choice. Enter 0-{0}." -f $eligible.Count) -ForegroundColor Yellow
            $idx = -1
        }
    } while ($idx -lt 0)

    if ($idx -eq 0) {
        Write-Host "Returning to geography selection..." -ForegroundColor Cyan
        $Regions = $null; $Geography = $null
        continue
    }
    $Location = $eligible[$idx - 1].Region
    Write-Host ("Selected: {0} ({1})" -f $eligible[$idx - 1].DisplayName, $Location) -ForegroundColor Green

    if ($eligible[$idx - 1].Eligible -eq 'QUOTA') {
        $selApp   = $appByRegion[$Location]
        $curLimit = if ($null -ne $selApp.SkuLimit) { [int]$selApp.SkuLimit } else { 0 }
        $curUsed  = if ($null -ne $selApp.SkuUsed)  { [int]$selApp.SkuUsed }  else { 0 }
        # +1 over the current limit, or enough to cover the instances needed, whichever is higher
        $newLimit = [Math]::Max($curLimit + 1, $curUsed + $AppServiceInstances)

        Write-Host ''
        Write-Warning ("{0} has App Service {1} quota {2}/{3} (used/limit). The NMM deployment will fail with a quota error unless the limit is raised." -f $Location, $AppServiceSku, $curUsed, $curLimit)
        $ans = Read-Host ("Request a {0} quota increase in {1} from {2} to {3} now? [Y/n]" -f $AppServiceSku, $Location, $curLimit, $newLimit)

        if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^[Yy]') {
            Write-Host ("  Submitting {0} quota request ({1} -> {2})..." -f $AppServiceSku, $curLimit, $newLimit) -ForegroundColor Cyan
            $qr = Request-AppServiceQuotaIncrease -Region $Location -Sub $subId -Sku $AppServiceSku `
                    -NewLimit $newLimit -ApiVersion $quotaApiVersion
            if ($qr.Ok) {
                Write-Host ("  Quota increased: {0} limit in {1} is now {2}." -f $AppServiceSku, $Location, $qr.Limit) -ForegroundColor Green
                if ($qr.Message) { Write-Host ("  Note: {0}" -f $qr.Message) -ForegroundColor Yellow }
            } else {
                Write-Host ("  Quota increase failed: {0}" -f $qr.Message) -ForegroundColor Red
                Write-Host ("  Manual option: Portal > Quotas > App Service (Public Preview) > Region '{0}' > {1} VMs > pencil icon, or open a 'Service and subscription limits (quotas)' support request." -f $eligible[$idx - 1].DisplayName, $AppServiceSku) -ForegroundColor Yellow
                $go = Read-Host "Continue with deployment anyway? [y/N, B = back to region selection]"
                if ($go -match '^[Bb]') { $Regions = $null; $Geography = $null; continue }
                if ($go -notmatch '^[Yy]') {
                    Write-Host "Exiting without deploying." -ForegroundColor Yellow
                    return
                }
            }
        } else {
            $go = Read-Host "Continue with deployment WITHOUT increasing quota (it will likely fail)? [y/N, B = back to region selection]"
            if ($go -match '^[Bb]') { $Regions = $null; $Geography = $null; continue }
            if ($go -notmatch '^[Yy]') {
                Write-Host "Exiting without deploying." -ForegroundColor Yellow
                return
            }
        }
    }

    break   # region chosen (and quota handled) -> continue to deployment
}

# ====================================================================
#  Phase 4: Deployment
# ====================================================================
Write-Banner "Deploying NMM"
try {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
    Write-Host ("Created resource group '{0}' in {1}." -f $ResourceGroupName, $Location) -ForegroundColor Green
} catch {
    Write-Host "Could not create resource group '$ResourceGroupName': $_" -ForegroundColor Red
    return
}

Write-Host "Accepting Azure Marketplace terms for nerdio/nmm/nmm-plan..." -ForegroundColor Cyan
$termsOutput = az vm image terms accept --publisher nerdio --offer nmm --plan nmm-plan --only-show-errors 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Marketplace terms accepted." -ForegroundColor Green
} else {
    Write-Warning ("Could not accept marketplace terms: {0}" -f ($termsOutput -join ' '))
    Write-Warning "If deployment fails with MarketplacePurchaseEligibilityFailed, the subscription type may not allow marketplace purchases (e.g. CSP/MSDN/sponsored), or a private marketplace policy may be blocking the publisher."
}

$SqlPassword    = New-StrongPassword -Length 20
$deploymentName = "nmm-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"

$templatePath = Join-Path ([System.IO.Path]::GetTempPath()) "nmm-template-$(Get-Random).json"
$nmmTemplateJson | Out-File -FilePath $templatePath -Encoding UTF8

$job = $null
try {
    $job = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile $templatePath `
        -TemplateParameterObject @{ sqlServerPassword = $SqlPassword } `
        -AsJob -ErrorAction Stop
} catch {
    Write-Host "Could not start the deployment: $_" -ForegroundColor Red
}
if (-not $job) {
    Remove-Item $templatePath -ErrorAction SilentlyContinue
    Write-Host "Nothing was deployed. Delete the empty resource group '$ResourceGroupName' before re-running with the same name." -ForegroundColor Yellow
    return
}

Write-Host "Deployment '$deploymentName' started..." -ForegroundColor Cyan
$start = Get-Date
while ($job.State -in 'NotStarted', 'Running') {
    $elapsed = (Get-Date) - $start
    $d = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $deploymentName -ErrorAction SilentlyContinue
    $state = if ($d) { $d.ProvisioningState } else { 'Starting' }
    Write-Host ("`r[{0:hh\:mm\:ss}] {1}    " -f $elapsed, $state) -NoNewline
    Start-Sleep -Seconds 10
}
Write-Host ""

$deployOk = $false
try {
    $result = Receive-Job -Job $job -Wait -ErrorAction Stop | Select-Object -Last 1
    if ($result.ProvisioningState -ne 'Succeeded') {
        throw "Deployment finished with state '$($result.ProvisioningState)'."
    }
    $deployOk = $true
    Write-Host "Deployment succeeded." -ForegroundColor Green
}
catch {
    Write-Host "Deployment failed: $_" -ForegroundColor Red
    $failed = Get-AzResourceGroupDeploymentOperation -ResourceGroupName $ResourceGroupName `
        -DeploymentName $deploymentName -ErrorAction SilentlyContinue |
        Where-Object { $_.ProvisioningState -eq 'Failed' }
    if ($failed) {
        $failed | ForEach-Object {
            Write-Host "---"
            Write-Host "Resource: $($_.TargetResource)"
            Write-Host "Status:   $($_.StatusCode)"
            Write-Host "Message:  $($_.StatusMessage)"
        }
    } else {
        Write-Host "(No deployment record — failure occurred before submission to Azure.)"
    }
}
finally {
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item $templatePath -ErrorAction SilentlyContinue
}
if (-not $deployOk) { return }

# ====================================================================
#  Phase 5: Post-install configuration
# ====================================================================
Write-Banner "Configuring NMM"
$app = Get-AzResource -ResourceGroupName $ResourceGroupName `
    -ResourceType 'Microsoft.Solutions/applications' -ExpandProperties -ErrorAction SilentlyContinue | Select-Object -First 1
$managedRg = if ($app) { ($app.Properties.managedResourceGroupId -split '/')[-1] }
$webapp = if ($managedRg) {
    Get-AzWebApp -ResourceGroupName $managedRg -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'web-admin-portal-*' } | Select-Object -First 1
}
if (-not $webapp) {
    Write-Host "Deployment succeeded, but the NMM admin portal web app wasn't found in managed resource group '$managedRg'." -ForegroundColor Red
    Write-Host "Open the managed application in the Azure portal to finish setup." -ForegroundColor Yellow
    return
}
$url = "https://$($webapp.DefaultHostName)"
Write-Host "Web app URL: $url" -ForegroundColor Cyan

# 502/503/504 mean App Service is still starting. NMM has returned 500 before post-install config runs, so 500 counts as up.
Write-Host "Waiting for web app to respond" -NoNewline
$ready   = $false
$timeout = (Get-Date).AddMinutes(20)
while ((Get-Date) -lt $timeout) {
    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop
        if ($r.StatusCode -notin 502, 503, 504) { $ready = $true; break }
    } catch {}
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 15
}
Write-Host ""
if ($ready) {
    Write-Host "Web app responded (HTTP $($r.StatusCode))." -ForegroundColor Green
} else {
    Write-Warning "Web app didn't respond within 20 minutes. Trying the post-install configuration anyway."
}

Write-Host "Running NMM post-install configuration..." -ForegroundColor Cyan
try {
    $configBody = @{
        app   = $webapp.Name
        rg    = $managedRg
        subId = $subId
    } | ConvertTo-Json -Compress

    $configScript = Invoke-RestMethod `
        -Uri 'https://nmm-live-maintenance.azurewebsites.net/api/packages/6.8.0/script/install' `
        -Method POST `
        -Body $configBody `
        -ContentType 'application/json' `
        -ErrorAction Stop

    & ([ScriptBlock]::Create($configScript))
    Write-Host "Post-install configuration complete." -ForegroundColor Green
} catch {
    Write-Host "Post-install configuration failed: $_" -ForegroundColor Red
    Write-Host "You can run it manually by visiting: $url" -ForegroundColor Yellow
}
