#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$AppServiceSku       = 'B2',
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

$NmmRequiredProviders = @(
    'Microsoft.KeyVault','Microsoft.Compute','Microsoft.Automation','Microsoft.Storage',
    'Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.DesktopVirtualization',
    'Microsoft.Network','Microsoft.AAD','Microsoft.RecoveryServices','Microsoft.Web',
    'Microsoft.Quota','Microsoft.Solutions','Microsoft.Sql','Microsoft.Marketplace'
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
    $upper   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
    $lower   = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $digit   = '0123456789'.ToCharArray()
    $special = '!@#$%^&*'.ToCharArray()
    $all = $upper + $lower + $digit + $special
    $chars = @(
        (Get-Random -InputObject $upper),
        (Get-Random -InputObject $lower),
        (Get-Random -InputObject $digit),
        (Get-Random -InputObject $special)
    )
    $chars += 1..($Length - 4) | ForEach-Object { Get-Random -InputObject $all }
    -join ($chars | Sort-Object { Get-Random })
}

function Get-SqlRegionStatus {
    param(
        [string]$Region, [string]$Sub, [string]$Token,
        [string]$Edition, [string]$Slo, [string]$ApiVersion
    )
    $uri = "https://management.azure.com/subscriptions/$Sub/providers/Microsoft.Sql/locations/$Region/capabilities?api-version=$ApiVersion&include=supportedEditions"
    try {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
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
    $allSubs = az account list --only-show-errors 2>$null | ConvertFrom-Json
    if (-not $allSubs -or @($allSubs).Count -eq 0) {
        throw "No Azure subscriptions found. Run 'az login' first."
    }
    if (@($allSubs).Count -eq 1) {
        $SubscriptionId = $allSubs[0].id
        Write-Host ("Using only available subscription: {0}" -f $allSubs[0].name) -ForegroundColor DarkGray
    } else {
        Write-Host ''
        Write-Host "Select an Azure subscription:" -ForegroundColor Cyan
        $defaultIdx = 1
        for ($i = 0; $i -lt $allSubs.Count; $i++) {
            $marker = if ($allSubs[$i].isDefault) { ' (current)' } else { '' }
            Write-Host ("  {0,2}. {1}  [{2}]{3}" -f ($i + 1), $allSubs[$i].name, $allSubs[$i].id, $marker)
            if ($allSubs[$i].isDefault) { $defaultIdx = $i + 1 }
        }
        $pick = Read-Host "Enter choice [$defaultIdx]"
        if ([string]::IsNullOrWhiteSpace($pick)) { $pick = $defaultIdx }
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $allSubs.Count) {
            throw "Invalid subscription choice."
        }
        $SubscriptionId = $allSubs[$idx - 1].id
        Write-Host ("Selected: {0}" -f $allSubs[$idx - 1].name) -ForegroundColor Green
    }
}

az account set --subscription $SubscriptionId --only-show-errors | Out-Null
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue | Out-Null

$ctx = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
$subId = $ctx.id

$token = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $token) { throw "Could not acquire Azure access token." }

Write-Banner "Nerdio Manager for MSP (NMM) - Pre-Install Readiness Check"
Write-Host ("Subscription : {0}" -f $ctx.name)
Write-Host ("Sub ID       : {0}" -f $ctx.id)
Write-Host ("Checking for : App Service '{0}'  +  Azure SQL '{1}/{2}'" -f $AppServiceSku, $SqlEdition, $SqlServiceObjective)
Write-Host ''

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
    "{0,-55} {1}" -f "  Entra ID Global Administrator", $gaLabel | Write-Host -ForegroundColor $gaColor
    Write-Host ''

    if ((-not $isOwner) -or ($isGA -eq $false)) {
        Write-Host '  ACTION REQUIRED: Missing permissions will cause the NMM install to fail.' -ForegroundColor Red
        if (-not $isOwner)   { Write-Host ("  -> Assign Owner on subscription '{0}'." -f $ctx.name) -ForegroundColor Red }
        if ($isGA -eq $false){ Write-Host '  -> Assign Global Administrator in Entra ID.' -ForegroundColor Red }
        Write-Host '  (Continuing for informational purposes...)' -ForegroundColor DarkGray
    } else {
        Write-Host '  All required permissions confirmed.' -ForegroundColor Green
    }
}

# ====================================================================
#  Phase 1: Resource provider registration
# ====================================================================
Write-Banner "Phase 1: Resource Provider Registration"
$providerResults = [System.Collections.Generic.List[object]]::new()
foreach ($ns in $NmmRequiredProviders) {
    $state = az provider show --namespace $ns --query registrationState --output tsv --only-show-errors 2>$null
    if (-not $state) { $state = 'UNKNOWN' }
    $providerResults.Add([pscustomobject]@{ Provider = $ns; State = $state })
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
        $pending = [System.Collections.Generic.List[string]]::new()
        foreach ($ns in $NmmRequiredProviders) {
            $state = az provider show --namespace $ns --query registrationState --output tsv --only-show-errors 2>$null
            if ($state -and $state -ne 'Registered') { $pending.Add("$ns ($state)") }
        }
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

Write-Host ("Querying App Service regions that offer '{0}'..." -f $AppServiceSku) -ForegroundColor DarkGray
$appSvcRaw   = az appservice list-locations --sku $AppServiceSku --only-show-errors 2>$null | ConvertFrom-Json
$appSvcSlugs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $appSvcRaw) {
    $slug = if ($nameToSlug.ContainsKey($r.name)) { $nameToSlug[$r.name] } else { ($r.name -replace '\s','').ToLower() }
    [void]$appSvcSlugs.Add($slug)
}
Write-Host ("  -> {0} regions offer App Service {1}." -f $appSvcSlugs.Count, $AppServiceSku) -ForegroundColor DarkGray

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
    return
}

$apiVersion  = '2023-05-01-preview'
$candidates  = @($candidates)
$useParallel = ($PSVersionTable.PSVersion.Major -ge 7) -and ($candidates.Count -gt 3)

if ($useParallel) {
    $funcDef = ${function:Get-SqlRegionStatus}.ToString()
    $sqlResults = $candidates | ForEach-Object -Parallel {
        ${function:Get-SqlRegionStatus} = $using:funcDef
        Get-SqlRegionStatus -Region $_ -Sub $using:subId -Token $using:token `
            -Edition $using:SqlEdition -Slo $using:SqlServiceObjective -ApiVersion $using:apiVersion
    } -ThrottleLimit 15
} else {
    $sqlResults = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($slug in $candidates) {
        $i++
        Write-Progress -Activity "Checking SQL availability" -Status $slug -PercentComplete ([int](($i / $candidates.Count) * 100))
        $sqlResults.Add( (Get-SqlRegionStatus -Region $slug -Sub $subId -Token $token `
            -Edition $SqlEdition -Slo $SqlServiceObjective -ApiVersion $apiVersion) )
    }
    Write-Progress -Activity "Checking SQL availability" -Completed
}

$sqlByRegion = @{}
foreach ($s in $sqlResults) { $sqlByRegion[$s.Region] = $s }

$results = New-Object System.Collections.Generic.List[object]
foreach ($slug in $candidates) {
    $appOk     = $appSvcSlugs.Contains($slug)
    $sql       = $sqlByRegion[$slug]
    $sqlOk     = [bool]($sql -and $sql.Ok)
    $display   = if ($slugToName.ContainsKey($slug)) { $slugToName[$slug] } else { $slug }
    $results.Add([pscustomobject]@{
        Region           = $slug
        DisplayName      = $display
        AppService       = if ($appOk) { 'Yes' } else { 'No' }
        SqlDb            = if ($sqlOk) { 'Yes' } else { 'No' }
        Eligible         = if ($appOk -and $sqlOk) { 'YES' } else { 'no' }
        SqlReason        = if ($sqlOk) { '' } else { if ($sql) { $sql.Reason } else { 'no SQL result' } }
        AppServiceReason = if ($appOk) { '' } else { "App Service $AppServiceSku not offered" }
    })
}

$sorted   = $results | Sort-Object @{E={$_.Eligible -eq 'YES'};Descending=$true}, DisplayName
$eligible = @($sorted | Where-Object { $_.Eligible -eq 'YES' })

Write-Banner "Results"
$sorted | Format-Table Region, DisplayName, AppService, SqlDb, Eligible -AutoSize | Out-Host

if ($OutFile) {
    $sorted | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
    Write-Host ("Results CSV: {0}" -f $OutFile) -ForegroundColor Cyan
}

if ($eligible.Count -eq 0) {
    Write-Host "No region offers BOTH App Service $AppServiceSku and SQL $SqlEdition/$SqlServiceObjective. Exiting." -ForegroundColor Red
    return
}

# ====================================================================
#  Phase 3: Region picker
# ====================================================================
Write-Banner "Select a region for NMM deployment"
for ($i = 0; $i -lt $eligible.Count; $i++) {
    Write-Host ("  {0,2}. {1}  ({2})" -f ($i + 1), $eligible[$i].DisplayName, $eligible[$i].Region)
}
$pick = Read-Host "`nEnter choice [1]"
if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
$idx = 0
if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $eligible.Count) {
    Write-Host "Invalid choice. Exiting." -ForegroundColor Red
    return
}
$Location = $eligible[$idx - 1].Region
Write-Host ("Selected: {0} ({1})" -f $eligible[$idx - 1].DisplayName, $Location) -ForegroundColor Green

# ====================================================================
#  Phase 4: Deployment
# ====================================================================
Write-Banner "Deploying NMM"
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location
}

Write-Host "Checking Azure Marketplace terms for nerdio/nmm/nmm-plan..." -ForegroundColor Cyan
try {
    $terms = Get-AzMarketplaceTerms -Publisher 'nerdio' -Product 'nmm' -Name 'nmm-plan' -ErrorAction Stop
    if (-not $terms.Accepted) {
        Set-AzMarketplaceTerms -Publisher 'nerdio' -Product 'nmm' -Name 'nmm-plan' -Terms $terms -Accept | Out-Null
        Write-Host "Marketplace terms accepted." -ForegroundColor Green
    } else {
        Write-Host "Marketplace terms already accepted." -ForegroundColor DarkGray
    }
} catch {
    Write-Warning "Could not accept marketplace terms automatically: $_"
    Write-Warning "If deployment fails with MarketplacePurchaseEligibilityFailed, the subscription type may not allow marketplace purchases (e.g. CSP/MSDN/sponsored), or a private marketplace policy may be blocking the publisher."
}

$SqlPassword    = New-StrongPassword -Length 20
$deploymentName = "nmm-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"

$templatePath = Join-Path ([System.IO.Path]::GetTempPath()) "nmm-template-$(Get-Random).json"
$nmmTemplateJson | Out-File -FilePath $templatePath -Encoding UTF8

$job = New-AzResourceGroupDeployment `
    -Name $deploymentName `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $templatePath `
    -TemplateParameterObject @{ sqlServerPassword = $SqlPassword } `
    -AsJob

Write-Host "Deployment '$deploymentName' started..." -ForegroundColor Cyan
$start = Get-Date
while ($job.State -eq 'Running') {
    $elapsed = (Get-Date) - $start
    $d = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $deploymentName -ErrorAction SilentlyContinue
    $state = if ($d) { $d.ProvisioningState } else { 'Starting' }
    Write-Host ("`r[{0:hh\:mm\:ss}] {1}    " -f $elapsed, $state) -NoNewline
    Start-Sleep -Seconds 10
}
Write-Host ""

try {
    $result = Receive-Job -Job $job -Wait -ErrorAction Stop
    Write-Host "Deployment succeeded ($($result.ProvisioningState))." -ForegroundColor Green

    $app = Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.Solutions/applications' -ExpandProperties | Select-Object -First 1
    $managedRg = ($app.Properties.managedResourceGroupId -split '/')[-1]
    $webapp    = Get-AzWebApp -ResourceGroupName $managedRg | Select-Object -First 1
    $url       = "https://$($webapp.DefaultHostName)"
    Write-Host "Web app URL: $url" -ForegroundColor Cyan

    Write-Host "Waiting for web app to respond" -NoNewline
    $timeout = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $timeout) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop
            Write-Host ""
            Write-Host "Web app responded (HTTP $($r.StatusCode))." -ForegroundColor Green
            break
        } catch {
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 15
        }
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
    if ($templatePath -and (Test-Path $templatePath)) {
        Remove-Item $templatePath -ErrorAction SilentlyContinue
    }
}
