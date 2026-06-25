# UEFI Secure Boot CA Firmware Data

[![Update UEFI Secure Boot CA Firmware Data](https://github.com/AU-Mark/UEFI-Secure-Boot-CA-Firmware-Data/actions/workflows/update-data.yml/badge.svg)](https://github.com/AU-Mark/UEFI-Secure-Boot-CA-Firmware-Data/actions/workflows/update-data.yml)

Automated collection of UEFI Secure Boot 2023 certificate minimum firmware versions from Dell, HP, and Lenovo.

## Features

- **Dynamic Daily Updates**: Automatically checks for minimum firmware version updates daily at 6:00 AM UTC
- **Multi-Vendor Support**: Maintains data for Dell, HP, and Lenovo platforms
- **Version Tracking**: Records minimum BIOS/firmware versions required for UEFI Secure Boot CA 2023
- **Structured Data**: JSON format for easy integration with scripts and automation

## Data Files

| File | Description |
| --- | --- |
| `data/Dell.json` | Dell platforms and minimum BIOS versions |
| `data/HP.json` | HP platforms and minimum BIOS versions |
| `data/Lenovo.json` | Lenovo platforms and minimum BIOS versions |

## JSON Schema

All vendors share the same flat schema:

```json
{
  "Vendor": "Lenovo",
  "LastUpdated": "2026-06-25T18:40:35Z",
  "SourceUrl": "https://support.lenovo.com/us/en/solutions/ht518129",
  "RecordCount": 495,
  "Data": [
    {
      "Model": "ThinkPad E14 Gen 1",
      "MinFirmwareVersion": "R16ET45W (v1.31)"
    }
  ]
}
```

## Usage

### Raw JSON URLs

```text
https://raw.githubusercontent.com/AU-Mark/UEFI-Secure-Boot-CA-Firmware-Data/main/data/Dell.json
https://raw.githubusercontent.com/AU-Mark/UEFI-Secure-Boot-CA-Firmware-Data/main/data/HP.json
https://raw.githubusercontent.com/AU-Mark/UEFI-Secure-Boot-CA-Firmware-Data/main/data/Lenovo.json
```

### PowerShell Example

```powershell
# Load data from GitHub (recommended)
$lenovoData = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/AU-Mark/UEFI-Secure-Boot-CA-Firmware-Data/main/data/Lenovo.json"

# Find a specific model
$lenovoData.Data | Where-Object { $_.Model -like "*ThinkPad E14*" }

# Check if a system meets requirements (simple string compare; formats vary by vendor)
$entry = $lenovoData.Data | Where-Object { $_.Model -eq "ThinkPad E14 Gen 1" }
Write-Host "Minimum BIOS: $($entry.MinFirmwareVersion)"
```

## How It Works

1. **Selenium Stealth**: Uses Chrome with stealth options to bypass bot detection. HP and Lenovo are behind Akamai; Dell uses a plain HTTP request.
2. **HTML Parsing**: Extracts model names and firmware versions from vendor pages. Lenovo's HT518129 model tables use rowspan, which is expanded before extraction.
3. **Data Validation**: Verifies extracted data before updating JSON files.
4. **Automatic Updates**: GitHub Actions runs daily to check for changes.

## Data Sources

- **Dell**: [Microsoft 2011 Secure Boot Certificate Expiration](https://www.dell.com/support/kbdoc/en-us/000347876/microsoft-2011-secure-boot-certificate-expiration)
- **HP**: [HP Commercial PCs - Prepare for new Windows Secure Boot certificates](https://support.hp.com/us-en/document/ish_13070353-13070429-16)
- **Lenovo**: [Lenovo Secure Boot Certificate Expiration Guide (HT518129)](https://support.lenovo.com/us/en/solutions/ht518129)

## Certificate Information

The Microsoft Secure Boot certificates expiring in 2026:

| Certificate | Expiration Date | New Certificate |
| --- | --- | --- |
| Microsoft Corporation KEK CA 2011 | June 25, 2026 | Microsoft Corporation KEK 2K CA 2023 |
| Microsoft Windows Production PCA 2011 | October 20, 2026 | Windows UEFI CA 2023 |
| Microsoft UEFI CA 2011 | June 28, 2026 | Microsoft UEFI CA 2023 |

## Manual Trigger

The workflow can be manually triggered from the Actions tab if you need an immediate update.

## License

Data sourced from Dell, HP, and Lenovo public documentation.
