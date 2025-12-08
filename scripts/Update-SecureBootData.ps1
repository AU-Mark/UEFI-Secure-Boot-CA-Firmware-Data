<#
.SYNOPSIS
    Updates Secure Boot certificate firmware data from Dell and HP.

.DESCRIPTION
    Fetches the latest UEFI CA 2023 minimum firmware version data from Dell and HP
    support pages and saves them as standardized JSON files.

    Dell: Uses simple HTTP request (no bot protection)
    HP: Uses Selenium with stealth options (Akamai protection)

.PARAMETER OutputPath
    Path to the data folder. Defaults to ../data relative to script location.

.PARAMETER SkipHP
    Skip HP data extraction (useful if Selenium not available).

.PARAMETER SkipDell
    Skip Dell data extraction.

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
    [switch]$SkipDell
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
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Dell records: $(if ($results.Dell) { $results.Dell } else { 'FAILED' })" -ForegroundColor $(if ($results.Dell) { 'Green' } else { 'Red' })
Write-Host "  HP records: $(if ($results.HP) { $results.HP } else { 'FAILED' })" -ForegroundColor $(if ($results.HP) { 'Green' } else { 'Red' })
Write-Host "========================================" -ForegroundColor Cyan

# Return success/failure for CI/CD
if ($results.Dell -gt 0 -or $results.HP -gt 0) {
    exit 0
} else {
    exit 1
}

#endregion
