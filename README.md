# DNS Automation Utility

> PowerShell 5 script that standardizes DNS record management across enterprise zones — with built-in validation, audit logging, and confirmation safeguards.

---

## Overview

Manual DNS changes through the Windows DNS Manager console are slow and error-prone. This utility replaces that workflow with a structured, menu-driven PowerShell script that validates every input, logs every change, and requires confirmation before any destructive operation runs.

**Results after adoption:**
- Average task time reduced from ~15 minutes to under 5 minutes
- ~40% reduction in DNS-related misconfigurations
- Full audit trail of every change across enterprise zones

---

## Requirements

| Requirement | Detail |
|---|---|
| PowerShell | 5.0 or later (fully PS5 compatible — no PS7 features used) |
| Module | `DnsServer` (included with Windows Server DNS role or RSAT) |
| Permissions | Member of `DnsAdmins` group or Domain Admin |
| OS | Windows Server 2012 R2 or later |

---

## Quick Start

```powershell
# 1. Check the DnsServer module is available
Get-Module -ListAvailable -Name DnsServer

# 2. Allow script execution (run once as Administrator)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 3. Run the script
.\DNS-Automation.ps1
```

---

## Configuration

Edit the `$script:Config` block at the top of the script before running:

```powershell
$script:Config = @{
    DnsServer    = $env:COMPUTERNAME   # Your DC hostname — COMPUTERNAME works when run on the DC itself
    Zones        = @(
        "dummy.local"                   # Add your DNS zones here
    )
    LogDirectory = "C:\Logs\DNS"       # Log file output path
    DefaultTTL   = [System.TimeSpan]::FromHours(1)
    MaxTTLHours  = 24                  # Maximum TTL allowed (enforced by validation)
    MinTTLMins   = 5                   # Minimum TTL allowed (enforced by validation)
}
```

> **Running remotely?** Replace `$env:COMPUTERNAME` with the FQDN of your DC:
> ```powershell
> DnsServer = "dc01.dummy.local"
> ```

---

## Features

### Interactive Menu
No parameters needed — all inputs are prompted at runtime:

```
  +==========================================+
  |     Enterprise DNS Automation Utility    |
  |     Server : EC2AMAZ-ESKNMNI            |
  |     Zones  : 1 configured zone(s)       |
  +==========================================+

   [1]  Add A Record
   [2]  Add CNAME Record
   [3]  Update A Record
   [4]  Delete DNS Record
   [5]  View Zone Summary
   [6]  Search All Zones
   [Q]  Quit
```

### Input Validation
Every operation validates inputs before touching DNS:

| Check | Rule |
|---|---|
| Zone allowlist | Zone must exist in `$script:Config.Zones` |
| Hostname format | Alphanumeric and hyphens only, no leading/trailing hyphens |
| IPv4 format | Must be a valid dotted-decimal address |
| TTL range | Between `MinTTLMins` (5) and `MaxTTLHours × 60` (1440) minutes |
| Duplicate guard | `Add` operations abort if the record already exists |
| Existence guard | `Update` and `Delete` abort if the record does not exist |

### Confirmation Safeguards
- All write operations show a summary and require `y` before proceeding
- **Delete operations require double confirmation** — you must retype the record name exactly to proceed

### Structured Audit Logging
Every operation writes a timestamped entry to `C:\Logs\DNS\DNS_YYYY-MM-DD.log`:

```
2025-10-14T09:22:11 [AUDIT] User=jsmith Zone=dummy.local Record=FS01 :: CREATED A record FS01.dummy.local -> 10.10.1.100 TTL=60m
2025-10-14T11:05:44 [AUDIT] User=jsmith Zone=dummy.local Record=FS01 :: UPDATED A record FS01.dummy.local 10.10.1.100 -> 10.10.1.200 TTL=60m
2025-10-14T11:32:01 [AUDIT] User=jsmith Zone=dummy.local Record=TESTVM01 :: DELETED A record TESTVM01.dummy.local
```

Log levels: `INFO` · `WARN` · `AUDIT` · `ERROR`

---

## Functions Reference

| Function | Purpose |
|---|---|
| `Add-DNSARecord` | Create a new A (host) record |
| `Add-DNSCNameRecord` | Create a new CNAME (alias) record |
| `Update-DNSARecord` | Change the IP address of an existing A record |
| `Remove-DNSRecord` | Delete a record (A, CNAME, MX, TXT, PTR, SRV) |
| `Get-DNSZoneSummary` | List all A, CNAME, MX, TXT records in a zone |
| `Search-DNSRecord` | Find records across all zones by name or IP fragment |
| `Write-DNSLog` | Internal — structured log writer |
| `Get-RecordData` | Internal — PS5-compatible record data extractor |

---

## Verify a Record

After any operation, confirm the change took effect:

```powershell
# Using PowerShell
Resolve-DnsName FS01.dummy.local -Server EC2AMAZ-ESKNMNI

# Using nslookup
nslookup FS01.dummy.local EC2AMAZ-ESKNMNI
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `DnsServer module not found` | RSAT not installed | Run on the DC directly, or install RSAT DNS tools |
| `Access denied` | Insufficient permissions | Run as a member of `DnsAdmins` |
| `Zone X is not in allowed zones` | Zone not in config | Add the zone to `$script:Config.Zones` |
| `Cannot run script` (execution policy) | Restricted policy | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` |
| Record created but `Resolve-DnsName` fails | Client DNS cache | Run `ipconfig /flushdns` on the client |
| Log file not created | Missing write permissions | Ensure the account has write access to `C:\Logs\` |

---

## File Structure

```
DNS-Automation.ps1    # Main script — only file needed
C:\Logs\DNS\          # Auto-created log directory
  DNS_YYYY-MM-DD.log  # Daily rotating log file
```

---

## PS5 Compatibility Notes

This script is fully compatible with PowerShell 5.0. The following PS7-only features were explicitly avoided:

- `??` null-coalescing operator → replaced with `if/elseif` helper function `Get-RecordData`
- `[Parameter(Mandatory)]` shorthand → uses `[Parameter(Mandatory=$true)]` throughout
- Box-drawing Unicode characters → replaced with ASCII equivalents for console safety

---

## License

Internal use. Not for distribution outside the organization.
