# UEFI-CA-2023-Workstation-Support

Automated collection of UEFI Secure Boot 2023 certificate minimum firmware versions from Dell and HP.

## Overview

This repository maintains up-to-date JSON files containing the minimum BIOS/firmware versions required for Windows UEFI CA 2023 certificate support across Dell and HP platforms.

## Data Files

| File | Description |
|------|-------------|
| `data/Dell.json` | Dell platforms and minimum BIOS versions |
| `data/HP.json` | HP platforms and minimum BIOS versions |

## Data Format

Both JSON files use a standardized format:

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

### PowerShell

```powershell
# Load data
$dellData = Get-Content "data/Dell.json" | ConvertFrom-Json
$hpData = Get-Content "data/HP.json" | ConvertFrom-Json

# Find a specific model
$dellData.Data | Where-Object { $_.Model -like "*Latitude 5540*" }

# Check if a system meets requirements
$currentBios = "1.20.0"
$required = ($dellData.Data | Where-Object { $_.Model -eq "Latitude 5540" }).MinFirmwareVersion
if ([version]$currentBios -ge [version]$required) {
    Write-Host "BIOS meets requirements"
}
```

## Data Sources

- **Dell**: [Microsoft 2011 Secure Boot Certificate Expiration](https://www.dell.com/support/kbdoc/en-us/000347876/microsoft-2011-secure-boot-certificate-expiration)
- **HP**: [HP Commercial PCs - Prepare for new Windows Secure Boot certificates](https://support.hp.com/us-en/document/ish_13070353-13070429-16)

## Update Schedule

Data is automatically updated daily via GitHub Actions.

## Certificate Information

The Microsoft Secure Boot certificates expiring in 2026:

| Certificate | Expiration Date | New Certificate |
|-------------|-----------------|-----------------|
| Microsoft Corporation KEK CA 2011 | June 25, 2026 | Microsoft Corporation KEK 2K CA 2023 |
| Microsoft Windows Production PCA 2011 | October 20, 2026 | Windows UEFI CA 2023 |
| Microsoft UEFI CA 2011 | June 28, 2026 | Microsoft UEFI CA 2023 |

## License

Data sourced from Dell and HP public documentation.
