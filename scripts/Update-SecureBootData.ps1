<#
.SYNOPSIS
    Updates Secure Boot certificate firmware data from Dell, HP, and Lenovo.

.DESCRIPTION
    Fetches the latest UEFI CA 2023 minimum firmware version data from Dell, HP,
    and Lenovo support pages and saves them as standardized JSON files.

    Dell: Uses simple HTTP request (no bot protection)
    HP: Uses Selenium with stealth options (Akamai protection)
    Lenovo: Uses Selenium with stealth options (Akamai protection); the HT518129
            model tables use rowspan, which is expanded before extraction.

    All three vendors produce the same flat schema:
        { Vendor, LastUpdated, SourceUrl, RecordCount, Data: [ { Model, MinFirmwareVersion } ] }

.PARAMETER OutputPath
    Path to the data folder. Defaults to ../data relative to script location.

.PARAMETER SkipHP
    Skip HP data extraction (useful if Selenium not available).

.PARAMETER SkipDell
    Skip Dell data extraction.

.PARAMETER SkipLenovo
    Skip Lenovo data extraction.

.PARAMETER Verbose
    Show detailed progress information.

.EXAMPLE
    .\Update-SecureBootData.ps1

.EXAMPLE
    .\Update-SecureBootData.ps1 -SkipHP
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$SkipHP,

    [Parameter()]
    [switch]$SkipDell,

    [Parameter()]
    [switch]$SkipLenovo
)

# Add required assemblies
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# Set output path
if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "..\data"
}

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

#region Helper Functions

function ConvertFrom-HtmlTable {
    <#
    .SYNOPSIS
        Parses HTML table into PowerShell objects.
    #>
    param(
        [string]$Html,
        [string[]]$ExpectedHeaders = @()
    )

    $results = @()

    # Extract headers
    $headerPattern = '<th[^>]*>(.*?)</th>'
    $headers = @()
    $headerMatches = [regex]::Matches($Html, $headerPattern, 'IgnoreCase,Singleline')
    foreach ($h in $headerMatches) {
        $text = $h.Groups[1].Value -replace '<[^>]+>', ''
        $text = [System.Web.HttpUtility]::HtmlDecode($text.Trim())
        if ($text) { $headers += $text }
    }

    # If no th headers, try first row td
    if ($headers.Count -eq 0) {
        $firstRowMatch = [regex]::Match($Html, '<tr[^>]*>(.*?)</tr>', 'IgnoreCase,Singleline')
        if ($firstRowMatch.Success) {
            $cellMatches = [regex]::Matches($firstRowMatch.Groups[1].Value, '<td[^>]*>(.*?)</td>', 'IgnoreCase,Singleline')
            foreach ($c in $cellMatches) {
                $text = $c.Groups[1].Value -replace '<[^>]+>', ''
                $text = [System.Web.HttpUtility]::HtmlDecode($text.Trim())
                if ($text) { $headers += $text }
            }
        }
    }

    # Extract data rows
    $rowMatches = [regex]::Matches($Html, '<tr[^>]*>(.*?)</tr>', 'IgnoreCase,Singleline')
    $skipFirst = $headers.Count -gt 0

    foreach ($row in $rowMatches) {
        if ($skipFirst) { $skipFirst = $false; continue }

        $rowHtml = $row.Groups[1].Value
        if ($rowHtml -match '<th') { continue }

        $cells = @()
        $cellMatches = [regex]::Matches($rowHtml, '<td[^>]*>(.*?)</td>', 'IgnoreCase,Singleline')
        foreach ($c in $cellMatches) {
            $text = $c.Groups[1].Value -replace '<[^>]+>', ''
            $text = [System.Web.HttpUtility]::HtmlDecode($text.Trim())
            $cells += $text
        }

        if ($cells.Count -gt 0) {
            $obj = [ordered]@{}
            for ($i = 0; $i -lt $cells.Count; $i++) {
                $headerName = if ($i -lt $headers.Count -and $headers[$i]) { $headers[$i] } else { "Column$($i+1)" }
                $obj[$headerName] = $cells[$i]
            }
            $results += [PSCustomObject]$obj
        }
    }

    return $results
}

function Get-DellData {
    <#
    .SYNOPSIS
        Fetches Dell Secure Boot certificate data.
    #>
    param([string]$Url)

    Write-Host "[Dell] Fetching data from Dell..." -ForegroundColor Cyan
    Write-Host "[Dell] URL: $Url" -ForegroundColor Gray

    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36'

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $userAgent -TimeoutSec 60
        Write-Host "[Dell] Response: $($response.StatusCode)" -ForegroundColor Green

        $html = $response.Content

        # Find all tables
        $tablePattern = '<table[^>]*>([\s\S]*?)</table>'
        $tables = [regex]::Matches($html, $tablePattern, 'IgnoreCase')
        Write-Host "[Dell] Found $($tables.Count) tables" -ForegroundColor Cyan

        $allData = @()

        foreach ($table in $tables) {
            $tableHtml = $table.Value
            $rowCount = ([regex]::Matches($tableHtml, '<tr')).Count

            # Skip tables with too few rows
            if ($rowCount -lt 2) { continue }

            # Check if it has Platform and BIOS keywords (more flexible matching)
            $hasPlatform = $tableHtml -match 'Platform'
            $hasBios = $tableHtml -match 'BIOS'
            if (-not ($hasPlatform -and $hasBios)) { continue }

            $tableData = ConvertFrom-HtmlTable -Html $tableHtml

            foreach ($row in $tableData) {
                # Standardize to Model/MinFirmwareVersion
                $model = $null
                $version = $null

                # Try different possible column names
                if ($row.Platform) { $model = $row.Platform }
                if ($row.'Minimum BIOS Version with 2023 Certificate') { $version = $row.'Minimum BIOS Version with 2023 Certificate' }
                if ($row.'Minimum BIOS Version') { $version = $row.'Minimum BIOS Version' }
                if ($row.Column1 -and -not $model) { $model = $row.Column1 }
                if ($row.Column2 -and -not $version) { $version = $row.Column2 }

                if ($model -and $version) {
                    $allData += [PSCustomObject]@{
                        Model = $model.Trim()
                        MinFirmwareVersion = $version.Trim()
                    }
                }
            }
        }

        Write-Host "[Dell] Extracted $($allData.Count) records" -ForegroundColor Green
        return $allData

    } catch {
        Write-Error "[Dell] Failed to fetch data: $_"
        return $null
    }
}

function Get-HPDataSelenium {
    <#
    .SYNOPSIS
        Fetches HP Secure Boot certificate data using Selenium (for Akamai bypass).
    #>
    param([string]$Url)

    Write-Host "[HP] Fetching data using Selenium..." -ForegroundColor Cyan
    Write-Host "[HP] URL: $Url" -ForegroundColor Gray

    # Try to find Selenium module
    $seleniumModule = Get-Module -ListAvailable -Name Selenium
    if (-not $seleniumModule) {
        Write-Warning "[HP] Selenium module not found. Trying alternative method..."
        return Get-HPDataAlternative -Url $Url
    }

    # Find Selenium assemblies
    $seleniumPath = $seleniumModule.ModuleBase
    $assembliesPath = Join-Path $seleniumPath "assemblies"
    $webDriverDll = Join-Path $assembliesPath "WebDriver.dll"

    if (-not (Test-Path $webDriverDll)) {
        Write-Warning "[HP] WebDriver.dll not found. Trying alternative method..."
        return Get-HPDataAlternative -Url $Url
    }

    # Load WebDriver
    if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "WebDriver" })) {
        Add-Type -Path $webDriverDll -ErrorAction Stop
    }

    $driver = $null

    try {
        # Create Chrome options with stealth settings
        $chromeOptions = New-Object OpenQA.Selenium.Chrome.ChromeOptions
        $chromeOptions.AddExcludedArgument("enable-automation")
        $chromeOptions.AddArgument("--disable-blink-features=AutomationControlled")
        $chromeOptions.AddArgument("--disable-extensions")
        $chromeOptions.AddArgument("--disable-http2")
        $chromeOptions.AddArgument("--no-sandbox")
        $chromeOptions.AddArgument("--disable-dev-shm-usage")
        $chromeOptions.AddArgument("--disable-gpu")
        $chromeOptions.AddArgument("--disable-infobars")
        $chromeOptions.AddArgument("--disable-notifications")
        $chromeOptions.AddArgument("--disable-popup-blocking")
        $chromeOptions.AddArgument("--window-size=1920,1080")
        $chromeOptions.AddArgument("--start-maximized")
        $chromeOptions.AddArgument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36")
        $chromeOptions.AddArgument("--lang=en-US")
        $chromeOptions.AddArgument("--headless=new")
        $chromeOptions.AddArgument("--log-level=3")
        $chromeOptions.AddArgument("--silent")

        # Create service
        $chromeService = [OpenQA.Selenium.Chrome.ChromeDriverService]::CreateDefaultService($assembliesPath)
        $chromeService.HideCommandPromptWindow = $true
        $chromeService.SuppressInitialDiagnosticInformation = $true

        Write-Host "[HP] Starting Chrome..." -ForegroundColor Cyan
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($chromeService, $chromeOptions)
        $driver.Manage().Timeouts().PageLoad = [TimeSpan]::FromSeconds(60)

        Write-Host "[HP] Navigating to page..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($Url)
        Start-Sleep -Seconds 10

        Write-Host "[HP] Page loaded: $($driver.Title)" -ForegroundColor Green

        $html = $driver.PageSource

        # Check for errors
        if ($html -match "ERR_|can't be reached|Access Denied") {
            throw "Page load failed or blocked"
        }

        # Parse tables
        $tablePattern = '<table[^>]*>([\s\S]*?)</table>'
        $tables = [regex]::Matches($html, $tablePattern, 'IgnoreCase')
        Write-Host "[HP] Found $($tables.Count) tables" -ForegroundColor Cyan

        $allData = @()

        foreach ($table in $tables) {
            $tableHtml = $table.Value
            $rowCount = ([regex]::Matches($tableHtml, '<tr')).Count

            if ($rowCount -lt 3) { continue }

            # Check for HP model patterns
            if ($tableHtml -notmatch 'EliteBook|ProBook|ZBook|HP \d|EliteDesk|ProDesk|Engage|Product Name') { continue }

            $tableData = ConvertFrom-HtmlTable -Html $tableHtml

            foreach ($row in $tableData) {
                $model = $null
                $version = $null

                # HP uses different column names
                if ($row.'Product Name') { $model = $row.'Product Name' }
                if ($row.'Minimum BIOS Version') { $version = $row.'Minimum BIOS Version' }

                # Skip TBD entries
                if ($model -and $version -and $version -ne 'TBD') {
                    $allData += [PSCustomObject]@{
                        Model = $model.Trim()
                        MinFirmwareVersion = $version.Trim()
                    }
                }
            }
        }

        Write-Host "[HP] Extracted $($allData.Count) records" -ForegroundColor Green
        return $allData

    } catch {
        Write-Error "[HP] Selenium failed: $_"
        Write-Host "[HP] Trying alternative method..." -ForegroundColor Yellow
        return Get-HPDataAlternative -Url $Url
    } finally {
        if ($driver) {
            try { $driver.Quit() } catch { }
        }
    }
}

function Get-HPDataAlternative {
    <#
    .SYNOPSIS
        Tries to fetch HP data without Selenium (fallback method).
    #>
    param([string]$Url)

    Write-Host "[HP] Attempting direct fetch (may be blocked by Akamai)..." -ForegroundColor Yellow

    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36'

    $headers = @{
        "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
        "Accept-Language" = "en-US,en;q=0.5"
        "Accept-Encoding" = "gzip, deflate, br"
        "Cache-Control" = "no-cache"
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $userAgent -Headers $headers -TimeoutSec 60

        if ($response.StatusCode -eq 200 -and $response.Content -match 'EliteBook|ProBook|ZBook') {
            Write-Host "[HP] Direct fetch successful!" -ForegroundColor Green
            # Parse same as Selenium method
            # ... (would duplicate parsing code)
        }

        Write-Warning "[HP] Direct fetch returned but may be blocked. Check data quality."
        return $null

    } catch {
        Write-Error "[HP] Alternative method failed: $_"
        return $null
    }
}

# --- Lenovo (HT518129) -----------------------------------------------------
# The Lenovo Secure Boot guide is a JS-rendered SPA behind Akamai, and its model
# tables use rowspan (values 2/3/6, no colspan) on the Model and BIOS columns.
# Rows are expanded to full width before extraction so grouped products keep
# their shared minimum BIOS version.

function Get-LnvCleanText {
    param([string]$Html)
    if ([string]::IsNullOrEmpty($Html)) { return '' }
    $text = [regex]::Replace($Html, '(?s)<[^>]+>', ' ')
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace ([char]0x00A0), ' '
    $text = $text -replace '\s+', ' '
    return $text.Trim()
}

function Expand-LnvTableRows {
    <#
    .SYNOPSIS
        Returns a table's rows with rowspans expanded so every logical row has a
        full set of cells. Column count is taken from the header (first) row.
    #>
    param([string]$TableHtml)

    $rawRows = [regex]::Matches($TableHtml, '(?is)<tr\b.*?</tr>')
    if ($rawRows.Count -eq 0) { return @() }

    $colCount = ([regex]::Matches($rawRows[0].Value, '(?is)<(t[dh])\b[^>]*>(.*?)</\1>')).Count
    if ($colCount -lt 1) { $colCount = 3 }

    $carryCell = [object[]]::new($colCount)
    $carryRem  = [int[]]::new($colCount)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawRows) {
        $explicit = [regex]::Matches($raw.Value, '(?is)<(t[dh])\b([^>]*)>(.*?)</\1>')
        $ei = 0
        $row = [object[]]::new($colCount)
        for ($col = 0; $col -lt $colCount; $col++) {
            if ($carryRem[$col] -gt 0) {
                $row[$col] = $carryCell[$col]
                $carryRem[$col] = $carryRem[$col] - 1
            }
            elseif ($ei -lt $explicit.Count) {
                $m = $explicit[$ei]; $ei++
                $cell = [PSCustomObject]@{
                    Tag  = $m.Groups[1].Value.ToLower()
                    Text = (Get-LnvCleanText $m.Groups[3].Value)
                }
                $row[$col] = $cell
                $rs = [regex]::Match($m.Groups[2].Value, '(?i)rowspan\s*=\s*"?(\d+)')
                if ($rs.Success -and [int]$rs.Groups[1].Value -gt 1) {
                    $carryCell[$col] = $cell
                    $carryRem[$col]  = [int]$rs.Groups[1].Value - 1
                }
            }
            else {
                $row[$col] = [PSCustomObject]@{ Tag = 'td'; Text = '' }
            }
        }
        $rows.Add($row)
    }
    return $rows
}

function Format-LnvModelName {
    <#
    .SYNOPSIS
        Builds a full Lenovo model name, prefixing the product family only when
        the product does not already start with a known Lenovo brand.

    .DESCRIPTION
        Lenovo's anchors are product *categories*, not brands: the ideacentre
        table also lists LOQ and Legion desktops, and the WinBook table lists
        "Lenovo 100W/500W" education laptops. So prefixing by table family is
        wrong when the product already names a Lenovo line. Only genuinely
        brand-less rows (the bare ThinkPad models like "E14 Gen 1") get a prefix.
    #>
    param([string]$Family, [string]$Product)

    $p = $Product.Trim()
    if (-not $p) { return '' }

    # If the product already starts with a known Lenovo brand, keep it as-is.
    $brands = @('ThinkPad','ThinkStation','ThinkCentre','ThinkBook','ThinkSmart',
                'ThinkEdge','IdeaCentre','IdeaPad','Legion','Yoga','Lenovo','LOQ','WinBook')
    foreach ($b in $brands) {
        if ($p -match ('^(?i)' + [regex]::Escape($b))) { return $p }
    }

    # Brand-less product: prefix the family display name (skip combined anchors).
    if ($Family -match ',') { return $p }
    $display = @{
        'thinkpad'     = 'ThinkPad'
        'thinkstation' = 'ThinkStation'
        'thinkcentre'  = 'ThinkCentre'
        'thinkbook'    = 'ThinkBook'
        'winbook'      = 'WinBook'
        'thinksmart'   = 'ThinkSmart'
        'ideacentre'   = 'IdeaCentre'
    }
    $key = $Family.Trim().ToLower()
    if ($display.ContainsKey($key)) { return "$($display[$key]) $p" }
    return $p
}

function ConvertFrom-LenovoHtml {
    <#
    .SYNOPSIS
        Parses HT518129 page HTML into flat { Model, MinFirmwareVersion } records.

    .DESCRIPTION
        Walks every <table> (rowspans expanded first), skips the certificate
        cross-reference table, and for each model table emits one record per row.
        The product family comes from the nearest preceding <a id name> anchor.
    #>
    param([string]$Html)

    $anchors = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($Html, '(?is)<a\b(?=[^>]*\bid="([^"]+)")(?=[^>]*\bname=")[^>]*>(.*?)</a>')) {
        $anchors.Add([PSCustomObject]@{ Index = $m.Index; Text = (Get-LnvCleanText $m.Groups[2].Value) })
    }

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($tableMatch in [regex]::Matches($Html, '(?is)<table\b.*?</table>')) {
        $rows = Expand-LnvTableRows $tableMatch.Value
        if ($rows.Count -eq 0) { continue }

        $headerText = (($rows[0] | ForEach-Object { $_.Text }) -join ' | ')
        if ($headerText -match 'Expiring\s+Certificate') { continue }
        if (-not ($headerText -match 'Product' -and $headerText -match 'Model')) { continue }

        # Family from nearest preceding anchor.
        $family = 'Unknown'; $best = -1
        foreach ($a in $anchors) {
            if ($a.Index -lt $tableMatch.Index -and $a.Index -gt $best) { $best = $a.Index; $family = $a.Text }
        }

        for ($i = 0; $i -lt $rows.Count; $i++) {
            $c = $rows[$i]
            if ($c.Count -lt 3) { continue }
            if ($c[0].Tag -eq 'th' -or $c[0].Text -eq 'Product' -or $c[1].Text -eq 'Model') { continue }

            $product = $c[0].Text
            $minBios = $c[2].Text
            if (-not $product -or -not $minBios) { continue }

            $records.Add([PSCustomObject]@{
                Model              = (Format-LnvModelName -Family $family -Product $product)
                MinFirmwareVersion = $minBios
            })
        }
    }

    return $records
}

function Get-LenovoDataSelenium {
    <#
    .SYNOPSIS
        Fetches Lenovo Secure Boot model data using Selenium (Akamai bypass).
    #>
    param([string]$Url)

    Write-Host "[Lenovo] Fetching data using Selenium..." -ForegroundColor Cyan
    Write-Host "[Lenovo] URL: $Url" -ForegroundColor Gray

    $seleniumModule = Get-Module -ListAvailable -Name Selenium | Select-Object -First 1
    if (-not $seleniumModule) {
        Write-Warning "[Lenovo] Selenium module not found. Skipping."
        return $null
    }

    $assembliesPath = Join-Path $seleniumModule.ModuleBase "assemblies"
    $webDriverDll = Join-Path $assembliesPath "WebDriver.dll"
    if (-not (Test-Path $webDriverDll)) {
        Write-Warning "[Lenovo] WebDriver.dll not found. Skipping."
        return $null
    }

    if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "WebDriver" })) {
        Add-Type -Path $webDriverDll -ErrorAction Stop
    }

    $driver = $null
    try {
        $chromeOptions = New-Object OpenQA.Selenium.Chrome.ChromeOptions
        $chromeOptions.AddExcludedArgument("enable-automation")
        $chromeOptions.AddArgument("--disable-blink-features=AutomationControlled")
        $chromeOptions.AddArgument("--disable-extensions")
        $chromeOptions.AddArgument("--disable-http2")
        $chromeOptions.AddArgument("--no-sandbox")
        $chromeOptions.AddArgument("--disable-dev-shm-usage")
        $chromeOptions.AddArgument("--disable-gpu")
        $chromeOptions.AddArgument("--disable-infobars")
        $chromeOptions.AddArgument("--disable-notifications")
        $chromeOptions.AddArgument("--disable-popup-blocking")
        $chromeOptions.AddArgument("--window-size=1920,1080")
        $chromeOptions.AddArgument("--start-maximized")
        $chromeOptions.AddArgument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36")
        $chromeOptions.AddArgument("--lang=en-US")
        $chromeOptions.AddArgument("--headless=new")
        $chromeOptions.AddArgument("--log-level=3")
        $chromeOptions.AddArgument("--silent")

        $chromeService = [OpenQA.Selenium.Chrome.ChromeDriverService]::CreateDefaultService($assembliesPath)
        $chromeService.HideCommandPromptWindow = $true
        $chromeService.SuppressInitialDiagnosticInformation = $true

        Write-Host "[Lenovo] Starting Chrome..." -ForegroundColor Cyan
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($chromeService, $chromeOptions)
        $driver.Manage().Timeouts().PageLoad = [TimeSpan]::FromSeconds(60)

        Write-Host "[Lenovo] Navigating to page..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($Url)

        # Model tables load asynchronously after the SPA shell.
        $deadline = (Get-Date).AddSeconds(40)
        $tableCount = 0
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $tableCount = $driver.FindElements([OpenQA.Selenium.By]::TagName('table')).Count
            if ($tableCount -gt 0) { break }
        }

        Write-Host "[Lenovo] Page loaded: $($driver.Title)" -ForegroundColor Green
        Write-Host "[Lenovo] Tables rendered: $tableCount" -ForegroundColor Green

        $html = $driver.PageSource

        if ($html -match "Access Denied|Pardon the interruption|Request unsuccessful") {
            throw "Page returned a bot-protection / access-denied response."
        }
        if ($tableCount -eq 0) {
            throw "No tables rendered before timeout."
        }

        $records = ConvertFrom-LenovoHtml -Html $html
        Write-Host "[Lenovo] Extracted $($records.Count) records" -ForegroundColor Green
        return $records

    } catch {
        Write-Error "[Lenovo] Selenium failed: $_"
        return $null
    } finally {
        if ($driver) {
            try { $driver.Quit() } catch { }
        }
    }
}

# --- Dell out-of-scope list (KB 000378734) --------------------------------
# Dell publishes an explicit list of platforms with NO planned BIOS update for
# the 2023 certificates. The models are in HTML table cells (one model per <td>,
# grouped under <strong> family headers); Dell's product-picker widget uses bare
# family names with no model identifier, which are excluded. The page 403s for a
# bare User-Agent, so Accept headers are sent (Invoke-WebRequest defaults work in
# CI, but the headers make it robust).

function Get-DellOutOfScopeData {
    <#
    .SYNOPSIS
        Fetches Dell's out-of-scope (no planned BIOS update) model list.
    .OUTPUTS
        Sorted string[] of model names, or $null on failure.
    #>
    param([string]$Url)

    Write-Host "[Dell-OOS] Fetching out-of-scope list..." -ForegroundColor Cyan
    Write-Host "[Dell-OOS] URL: $Url" -ForegroundColor Gray

    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36'
    $headers = @{
        'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        'Accept-Language' = 'en-US,en;q=0.9'
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $userAgent -Headers $headers -TimeoutSec 60
        Write-Host "[Dell-OOS] Response: $($response.StatusCode)" -ForegroundColor Green

        $html = $response.Content
        $html = [regex]::Replace($html, '(?is)<script.*?</script>', ' ')
        $html = [regex]::Replace($html, '(?is)<style.*?</style>', ' ')

        # A model cell starts with a Dell product family followed by an identifier.
        $familyPattern = '^(Dell\s+)?(OptiPlex|Latitude|Precision|Vostro|Inspiron|XPS|Embedded|Wyse|Chromebook|Venue|Tablet)\b'
        # Bare family labels (Dell's product picker / section headers) are not models.
        $bareFamilies = @('Latitude', 'OptiPlex', 'Precision', 'Vostro', 'Inspiron', 'XPS', 'Embedded Box PC', 'Dell')

        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($m in [regex]::Matches($html, '(?is)<td[^>]*>(.*?)</td>')) {
            $text = [regex]::Replace($m.Groups[1].Value, '(?s)<[^>]+>', ' ')
            $text = [System.Net.WebUtility]::HtmlDecode($text)
            $text = ($text -replace '\s+', ' ').Trim()
            if ($text -and ($text -match $familyPattern) -and ($bareFamilies -notcontains $text)) {
                $null = $set.Add($text)
            }
        }

        $models = @($set | Sort-Object)
        Write-Host "[Dell-OOS] Extracted $($models.Count) out-of-scope models" -ForegroundColor Green
        return ,$models

    } catch {
        Write-Error "[Dell-OOS] Failed to fetch out-of-scope data: $_"
        return $null
    }
}

#endregion

#region Main Execution

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Secure Boot Certificate Data Updater" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Timestamp: $timestamp" -ForegroundColor Gray
Write-Host "Output: $OutputPath" -ForegroundColor Gray
Write-Host ""

$results = @{
    Dell = $null
    HP = $null
    Lenovo = $null
    DellOutOfScope = $null
}

# Fetch Dell data
if (-not $SkipDell) {
    $dellUrl = 'https://www.dell.com/support/kbdoc/en-us/000347876/microsoft-2011-secure-boot-certificate-expiration'
    $dellData = Get-DellData -Url $dellUrl

    if ($dellData -and $dellData.Count -gt 0) {
        $dellJson = [PSCustomObject]@{
            Vendor = "Dell"
            LastUpdated = $timestamp
            SourceUrl = $dellUrl
            RecordCount = $dellData.Count
            Data = $dellData
        }

        $dellPath = Join-Path $OutputPath "Dell.json"
        $dellJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $dellPath -Encoding UTF8
        Write-Host "[Dell] Saved to: $dellPath" -ForegroundColor Green
        $results.Dell = $dellData.Count
    } else {
        Write-Warning "[Dell] No data extracted"
    }

    # Fetch Dell out-of-scope list (supplementary - drives NotCapable detection)
    $dellOosUrl = 'https://www.dell.com/support/kbdoc/en-us/000378734/microsoft-2011-secure-boot-certificates-expiration-for-out-of-scope-platforms-for-bios-updates'
    $dellOos = Get-DellOutOfScopeData -Url $dellOosUrl

    if ($dellOos -and $dellOos.Count -gt 0) {
        $dellOosJson = [PSCustomObject]@{
            Vendor = "Dell"
            ListType = "OutOfScope"
            LastUpdated = $timestamp
            SourceUrl = $dellOosUrl
            RecordCount = $dellOos.Count
            Models = $dellOos
        }

        $dellOosPath = Join-Path $OutputPath "DellOutOfScope.json"
        $dellOosJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $dellOosPath -Encoding UTF8
        Write-Host "[Dell-OOS] Saved to: $dellOosPath" -ForegroundColor Green
        $results.DellOutOfScope = $dellOos.Count
    } else {
        Write-Warning "[Dell-OOS] No out-of-scope data extracted"
    }
}

Write-Host ""

# Fetch HP data
if (-not $SkipHP) {
    $hpUrl = 'https://support.hp.com/us-en/document/ish_13070353-13070429-16'
    $hpData = Get-HPDataSelenium -Url $hpUrl

    if ($hpData -and $hpData.Count -gt 0) {
        $hpJson = [PSCustomObject]@{
            Vendor = "HP"
            LastUpdated = $timestamp
            SourceUrl = $hpUrl
            RecordCount = $hpData.Count
            Data = $hpData
        }

        $hpPath = Join-Path $OutputPath "HP.json"
        $hpJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $hpPath -Encoding UTF8
        Write-Host "[HP] Saved to: $hpPath" -ForegroundColor Green
        $results.HP = $hpData.Count
    } else {
        Write-Warning "[HP] No data extracted"
    }
}

Write-Host ""

# Fetch Lenovo data
if (-not $SkipLenovo) {
    $lenovoUrl = 'https://support.lenovo.com/us/en/solutions/ht518129'
    $lenovoData = Get-LenovoDataSelenium -Url $lenovoUrl

    if ($lenovoData -and $lenovoData.Count -gt 0) {
        $lenovoJson = [PSCustomObject]@{
            Vendor = "Lenovo"
            LastUpdated = $timestamp
            SourceUrl = $lenovoUrl
            RecordCount = $lenovoData.Count
            Data = $lenovoData
        }

        $lenovoPath = Join-Path $OutputPath "Lenovo.json"
        $lenovoJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $lenovoPath -Encoding UTF8
        Write-Host "[Lenovo] Saved to: $lenovoPath" -ForegroundColor Green
        $results.Lenovo = $lenovoData.Count
    } else {
        Write-Warning "[Lenovo] No data extracted"
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Dell records: $(if ($results.Dell) { $results.Dell } else { 'FAILED' })" -ForegroundColor $(if ($results.Dell) { 'Green' } else { 'Red' })
Write-Host "  HP records: $(if ($results.HP) { $results.HP } else { 'FAILED' })" -ForegroundColor $(if ($results.HP) { 'Green' } else { 'Red' })
Write-Host "  Lenovo records: $(if ($results.Lenovo) { $results.Lenovo } else { 'FAILED' })" -ForegroundColor $(if ($results.Lenovo) { 'Green' } else { 'Red' })
Write-Host "  Dell out-of-scope: $(if ($results.DellOutOfScope) { $results.DellOutOfScope } else { 'FAILED' })" -ForegroundColor $(if ($results.DellOutOfScope) { 'Green' } else { 'Yellow' })
Write-Host "========================================" -ForegroundColor Cyan

# Return success/failure for CI/CD
if ($results.Dell -gt 0 -or $results.HP -gt 0 -or $results.Lenovo -gt 0) {
    exit 0
} else {
    exit 1
}

#endregion
