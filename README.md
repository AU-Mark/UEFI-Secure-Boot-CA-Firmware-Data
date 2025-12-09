# Secure Boot Certificate Firmware Data

[![Update Secure Boot Certificate Firmware Data](https://github.com/AU-Mark/UEFI-CA-2023-Workstation-Support/actions/workflows/update-data.yml/badge.svg)](https://github.com/AU-Mark/UEFI-CA-2023-Workstation-Support/actions/workflows/update-data.yml)

Automated collection of UEFI Secure Boot 2023 certificate minimum firmware versions from Dell and HP.

## Features

- **Daily Updates**: Automatically checks for firmware version updates daily at 6:00 AM UTC
- **Multi-Vendor Support**: Maintains data for Dell and HP platforms
- **Version Tracking**: Records minimum BIOS/firmware versions required for UEFI CA 2023
- **Structured Data**: JSON format for easy integration with scripts and automation

## Data Files

| File | Description |
|------|-------------|
| `data/Dell.json` | Dell platforms and minimum BIOS versions |
| `data/HP.json` | HP platforms and minimum BIOS versions |

## JSON Schema

```json
{
  "Vendor": "Dell",
  "LastUpdated": "2025-12-04T12:00:00Z",
  "SourceUrl": "https://...",
  "RecordCount": 340,
  "Data": [
    {
      "Model": "Latitude 5540",
      "MinFirmwareVersion": "1.25.0"
    }
  ]
}
```

## Usage

### Raw JSON URL

```
https://raw.githubusercontent.com/AU-Mark/UEFI-CA-2023-Workstation-Support/main/data/Dell.json
https://raw.githubusercontent.com/AU-Mark/UEFI-CA-2023-Workstation-Support/main/data/HP.json
```

### PowerShell Example

```powershell
# Load data from GitHub (recommended)
$dellData = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/AU-Mark/UEFI-CA-2023-Workstation-Support/main/data/Dell.json"
$hpData = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/AU-Mark/UEFI-CA-2023-Workstation-Support/main/data/HP.json"

# Find a specific model
$dellData.Data | Where-Object { $_.Model -like "*Latitude 5540*" }

# Check if a system meets requirements
$currentBios = "1.20.0"
$required = ($dellData.Data | Where-Object { $_.Model -eq "Latitude 5540" }).MinFirmwareVersion
if ([version]$currentBios -ge [version]$required) {
    Write-Host "BIOS meets requirements"
}
```

## How It Works

1. **Selenium Stealth**: Uses Chrome with stealth options to bypass bot detection
2. **HTML Parsing**: Extracts model names and firmware versions from vendor pages
3. **Data Validation**: Verifies extracted data before updating JSON files
4. **Automatic Updates**: GitHub Actions runs daily to check for changes

## Data Sources

- **Dell**: [Microsoft 2011 Secure Boot Certificate Expiration](https://www.dell.com/support/kbdoc/en-us/000347876/microsoft-2011-secure-boot-certificate-expiration)
- **HP**: [HP Commercial PCs - Prepare for new Windows Secure Boot certificates](https://support.hp.com/us-en/document/ish_13070353-13070429-16)

## Certificate Information

The Microsoft Secure Boot certificates expiring in 2026:

| Certificate | Expiration Date | New Certificate |
|-------------|-----------------|-----------------|
| Microsoft Corporation KEK CA 2011 | June 25, 2026 | Microsoft Corporation KEK 2K CA 2023 |
| Microsoft Windows Production PCA 2011 | October 20, 2026 | Windows UEFI CA 2023 |
| Microsoft UEFI CA 2011 | June 28, 2026 | Microsoft UEFI CA 2023 |

## Manual Trigger

The workflow can be manually triggered from the Actions tab if you need an immediate update.

## License

Data sourced from Dell and HP public documentation.
