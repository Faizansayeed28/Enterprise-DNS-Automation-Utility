#Requires -Version 5.0
#Requires -Modules DnsServer
<#
.SYNOPSIS
    Enterprise DNS Automation Utility
.DESCRIPTION
    Standardizes DNS record creation, updates, and deletion across enterprise zones.
    Includes input validation, execution safeguards, structured logging, and confirmation prompts.
.NOTES
    Requires DnsServer PowerShell module (RSAT or Windows Server DNS role)
    Compatible with PowerShell 5.0+
    Must be run with appropriate DNS admin privileges
#>

# ============================================================
#  CONFIGURATION — Edit these for your environment
# ============================================================
$script:Config = @{
    DnsServer    = $env:COMPUTERNAME
    Zones        = @(
        "Dummy.local"
    )
    LogDirectory = "C:\Logs\DNS"
    DefaultTTL   = [System.TimeSpan]::FromHours(1)
    MaxTTLHours  = 24
    MinTTLMins   = 5
}

# ============================================================
#  LOGGING
# ============================================================
function Write-DNSLog {
    param(
        [ValidateSet("INFO","WARN","ERROR","AUDIT")][string]$Level = "INFO",
        [string]$Message,
        [string]$Zone   = "",
        [string]$Record = ""
    )

    if (-not (Test-Path $script:Config.LogDirectory)) {
        New-Item -ItemType Directory -Path $script:Config.LogDirectory -Force | Out-Null
    }

    $logFile = Join-Path $script:Config.LogDirectory ("DNS_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
    $entry   = [PSCustomObject]@{
        Timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        Level     = $Level
        User      = $env:USERNAME
        Zone      = $Zone
        Record    = $Record
        Message   = $Message
    }

    $line = "{0} [{1,-5}] User={2} Zone={3} Record={4} :: {5}" -f `
        $entry.Timestamp, $entry.Level, $entry.User, $entry.Zone, $entry.Record, $entry.Message

    Add-Content -Path $logFile -Value $line -Encoding UTF8

    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "AUDIT" { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line -ForegroundColor Gray }
    }
}

# ============================================================
#  INPUT VALIDATION HELPERS
# ============================================================
function Assert-ValidZone {
    param([string]$Zone)
    if ($Zone -notin $script:Config.Zones) {
        throw "Zone '$Zone' is not in the allowed enterprise zones: $($script:Config.Zones -join ', ')"
    }
}

function Assert-ValidHostname {
    param([string]$Name)
    if ($Name -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$') {
        throw "Invalid hostname '$Name'. Must be a valid DNS label (alphanumeric and hyphens, no leading/trailing hyphens)."
    }
}

function Assert-ValidIPv4 {
    param([string]$IP)
    if (-not [System.Net.IPAddress]::TryParse($IP, [ref]$null)) {
        throw "Invalid IP address: '$IP'"
    }
    if ($IP -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        throw "Address must be IPv4: '$IP'"
    }
}

function Assert-ValidTTL {
    param([int]$TTLMinutes)
    $min = $script:Config.MinTTLMins
    $max = $script:Config.MaxTTLHours * 60
    if ($TTLMinutes -lt $min -or $TTLMinutes -gt $max) {
        throw "TTL must be between $min minutes and $max minutes ($($script:Config.MaxTTLHours) hours)."
    }
}

function Confirm-Action {
    param([string]$Action, [string]$Detail)
    Write-Host ""
    Write-Host "  ACTION  : $Action" -ForegroundColor Yellow
    Write-Host "  DETAIL  : $Detail" -ForegroundColor Yellow
    Write-Host ""
    $answer = Read-Host "  Confirm? [y/N]"
    return ($answer -match '^[Yy]$')
}

# ============================================================
#  DNS RECORD DATA HELPER  (replaces ?? null-coalescing)
# ============================================================
function Get-RecordData {
    param($Record)
    if ($Record.RecordData.IPv4Address) {
        return $Record.RecordData.IPv4Address.ToString()
    }
    elseif ($Record.RecordData.HostNameAlias) {
        return $Record.RecordData.HostNameAlias
    }
    elseif ($Record.RecordData.MailExchange) {
        return $Record.RecordData.MailExchange
    }
    elseif ($Record.RecordData.DescriptiveText) {
        return $Record.RecordData.DescriptiveText
    }
    else {
        return "(unknown)"
    }
}

# ============================================================
#  DNS RECORD OPERATIONS
# ============================================================
function Add-DNSARecord {
    <#
    .SYNOPSIS  Creates a new A record in the specified zone.
    .EXAMPLE   Add-DNSARecord -Zone "kpmg.local" -Name "webserver01" -IPAddress "10.10.1.50"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Zone,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$IPAddress,
        [int]$TTLMinutes = 60,
        [switch]$Force
    )

    try {
        Assert-ValidZone     $Zone
        Assert-ValidHostname $Name
        Assert-ValidIPv4     $IPAddress
        Assert-ValidTTL      $TTLMinutes

        $existing = Get-DnsServerResourceRecord -ZoneName $Zone -Name $Name -RRType A `
                        -ComputerName $script:Config.DnsServer -ErrorAction SilentlyContinue
        if ($existing) {
            throw "A record '$Name.$Zone' already exists (IP: $($existing.RecordData.IPv4Address)). Use Update-DNSARecord to modify it."
        }

        $fqdn   = "$Name.$Zone"
        $detail = "ADD A record  $fqdn  ->  $IPAddress  (TTL: ${TTLMinutes}m)"

        if (-not $Force -and -not (Confirm-Action "Create A Record" $detail)) {
            Write-DNSLog -Level WARN -Message "User cancelled ADD operation." -Zone $Zone -Record $Name
            return
        }

        $ttl = [System.TimeSpan]::FromMinutes($TTLMinutes)
        Add-DnsServerResourceRecordA -ZoneName $Zone -Name $Name -IPv4Address $IPAddress `
            -TimeToLive $ttl -ComputerName $script:Config.DnsServer -ErrorAction Stop

        Write-DNSLog -Level AUDIT -Message "CREATED A record $fqdn -> $IPAddress TTL=${TTLMinutes}m" -Zone $Zone -Record $Name
        Write-Host "`n  [OK] A record created: $fqdn -> $IPAddress" -ForegroundColor Green
    }
    catch {
        Write-DNSLog -Level ERROR -Message "Failed to create A record ${Name}.${Zone}: $_" -Zone $Zone -Record $Name
        Write-Host "`n  [FAIL] $_" -ForegroundColor Red
    }
}

function Add-DNSCNameRecord {
    <#
    .SYNOPSIS  Creates a CNAME record in the specified zone.
    .EXAMPLE   Add-DNSCNameRecord -Zone "kpmg.local" -Name "web" -HostNameAlias "webserver01.kpmg.local"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Zone,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$HostNameAlias,
        [int]$TTLMinutes = 60,
        [switch]$Force
    )

    try {
        Assert-ValidZone     $Zone
        Assert-ValidHostname $Name

        $existing = Get-DnsServerResourceRecord -ZoneName $Zone -Name $Name `
                        -ComputerName $script:Config.DnsServer -ErrorAction SilentlyContinue
        if ($existing) {
            throw "Record '$Name.$Zone' already exists. Use Remove then re-add to change it."
        }

        Assert-ValidTTL $TTLMinutes
        $fqdn   = "$Name.$Zone"
        $detail = "ADD CNAME  $fqdn  ->  $HostNameAlias  (TTL: ${TTLMinutes}m)"

        if (-not $Force -and -not (Confirm-Action "Create CNAME Record" $detail)) {
            Write-DNSLog -Level WARN -Message "User cancelled CNAME ADD." -Zone $Zone -Record $Name
            return
        }

        $ttl = [System.TimeSpan]::FromMinutes($TTLMinutes)
        Add-DnsServerResourceRecordCName -ZoneName $Zone -Name $Name -HostNameAlias $HostNameAlias `
            -TimeToLive $ttl -ComputerName $script:Config.DnsServer -ErrorAction Stop

        Write-DNSLog -Level AUDIT -Message "CREATED CNAME $fqdn -> $HostNameAlias TTL=${TTLMinutes}m" -Zone $Zone -Record $Name
        Write-Host "`n  [OK] CNAME created: $fqdn -> $HostNameAlias" -ForegroundColor Green
    }
    catch {
        Write-DNSLog -Level ERROR -Message "Failed to create CNAME ${Name}.${Zone}: $_" -Zone $Zone -Record $Name
        Write-Host "`n  [FAIL] $_" -ForegroundColor Red
    }
}

function Update-DNSARecord {
    <#
    .SYNOPSIS  Updates the IP address of an existing A record.
    .EXAMPLE   Update-DNSARecord -Zone "kpmg.local" -Name "webserver01" -NewIPAddress "10.10.1.55"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Zone,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$NewIPAddress,
        [int]$TTLMinutes = 60,
        [switch]$Force
    )

    try {
        Assert-ValidZone     $Zone
        Assert-ValidHostname $Name
        Assert-ValidIPv4     $NewIPAddress
        Assert-ValidTTL      $TTLMinutes

        $existing = Get-DnsServerResourceRecord -ZoneName $Zone -Name $Name -RRType A `
                        -ComputerName $script:Config.DnsServer -ErrorAction Stop

        $oldIP  = $existing.RecordData.IPv4Address.ToString()
        $fqdn   = "$Name.$Zone"
        $detail = "UPDATE A record  $fqdn  $oldIP  ->  $NewIPAddress  (TTL: ${TTLMinutes}m)"

        if (-not $Force -and -not (Confirm-Action "Update A Record" $detail)) {
            Write-DNSLog -Level WARN -Message "User cancelled UPDATE operation." -Zone $Zone -Record $Name
            return
        }

        $newRecord = $existing.Clone()
        $newRecord.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($NewIPAddress)
        $newRecord.TimeToLive             = [System.TimeSpan]::FromMinutes($TTLMinutes)

        Set-DnsServerResourceRecord -ZoneName $Zone -OldInputObject $existing -NewInputObject $newRecord `
            -ComputerName $script:Config.DnsServer -ErrorAction Stop

        Write-DNSLog -Level AUDIT -Message "UPDATED A record $fqdn $oldIP -> $NewIPAddress TTL=${TTLMinutes}m" -Zone $Zone -Record $Name
        Write-Host "`n  [OK] A record updated: $fqdn -> $NewIPAddress (was $oldIP)" -ForegroundColor Green
    }
    catch {
        Write-DNSLog -Level ERROR -Message "Failed to update A record ${Name}.${Zone}: $_" -Zone $Zone -Record $Name
        Write-Host "`n  [FAIL] $_" -ForegroundColor Red
    }
}

function Remove-DNSRecord {
    <#
    .SYNOPSIS  Deletes a DNS record from the specified zone. Requires double confirmation.
    .EXAMPLE   Remove-DNSRecord -Zone "kpmg.local" -Name "oldserver" -RRType A
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Zone,
        [Parameter(Mandatory=$true)][string]$Name,
        [ValidateSet("A","CNAME","MX","TXT","PTR","SRV")][string]$RRType = "A",
        [switch]$Force
    )

    try {
        Assert-ValidZone     $Zone
        Assert-ValidHostname $Name

        $existing = Get-DnsServerResourceRecord -ZoneName $Zone -Name $Name -RRType $RRType `
                        -ComputerName $script:Config.DnsServer -ErrorAction Stop

        $fqdn   = "$Name.$Zone"
        $detail = "DELETE $RRType record  $fqdn"

        if (-not $Force) {
            if (-not (Confirm-Action "DELETE DNS Record [DESTRUCTIVE]" $detail)) {
                Write-DNSLog -Level WARN -Message "User cancelled DELETE." -Zone $Zone -Record $Name
                return
            }
            Write-Host "  [!] Second confirmation required for deletion." -ForegroundColor Magenta
            $second = Read-Host "  Type the record name to confirm [$Name]"
            if ($second -ne $Name) {
                Write-DNSLog -Level WARN -Message "DELETE aborted - name confirmation mismatch." -Zone $Zone -Record $Name
                Write-Host "`n  [ABORTED] Name did not match. No changes made." -ForegroundColor Yellow
                return
            }
        }

        Remove-DnsServerResourceRecord -ZoneName $Zone -Name $Name -RRType $RRType `
            -ComputerName $script:Config.DnsServer -Force -ErrorAction Stop

        Write-DNSLog -Level AUDIT -Message "DELETED $RRType record $fqdn" -Zone $Zone -Record $Name
        Write-Host "`n  [OK] $RRType record deleted: $fqdn" -ForegroundColor Green
    }
    catch {
        Write-DNSLog -Level ERROR -Message "Failed to delete ${RRType} record ${Name}.${Zone}: $_" -Zone $Zone -Record $Name
        Write-Host "`n  [FAIL] $_" -ForegroundColor Red
    }
}

function Get-DNSZoneSummary {
    <#
    .SYNOPSIS  Lists all A, CNAME, MX, and TXT records in a zone.
    .EXAMPLE   Get-DNSZoneSummary -Zone "kpmg.local"
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Zone
    )

    try {
        Assert-ValidZone $Zone

        Write-Host "`n  Zone: $Zone" -ForegroundColor Cyan
        Write-Host "  Server: $($script:Config.DnsServer)" -ForegroundColor Cyan
        Write-Host ("  " + "-" * 60) -ForegroundColor DarkGray

        $records = Get-DnsServerResourceRecord -ZoneName $Zone `
                       -ComputerName $script:Config.DnsServer -ErrorAction Stop |
                   Where-Object { $_.RecordType -in @("A","CNAME","MX","TXT") } |
                   Sort-Object RecordType, HostName

        $records | Format-Table -AutoSize `
            @{Label="Name";   Expression={ $_.HostName }},
            @{Label="Type";   Expression={ $_.RecordType }},
            @{Label="TTL(s)"; Expression={ $_.TimeToLive.TotalSeconds }},
            @{Label="Data";   Expression={ Get-RecordData $_ }}

        Write-DNSLog -Level INFO -Message "Zone summary viewed for $Zone ($($records.Count) records)" -Zone $Zone
    }
    catch {
        Write-DNSLog -Level ERROR -Message "Failed to retrieve zone summary for ${Zone}: $_" -Zone $Zone
        Write-Host "`n  [FAIL] $_" -ForegroundColor Red
    }
}

function Search-DNSRecord {
    <#
    .SYNOPSIS  Searches all enterprise zones for records matching a name or IP pattern.
    .EXAMPLE   Search-DNSRecord -Pattern "web"
    .EXAMPLE   Search-DNSRecord -Pattern "10.10.1"
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Pattern
    )

    Write-Host "`n  Searching all zones for: '$Pattern'" -ForegroundColor Cyan

    foreach ($zone in $script:Config.Zones) {
        try {
            $records = Get-DnsServerResourceRecord -ZoneName $zone `
                           -ComputerName $script:Config.DnsServer -ErrorAction Stop |
                       Where-Object {
                           $_.HostName -like "*$Pattern*" -or
                           ($_.RecordData.IPv4Address  -and $_.RecordData.IPv4Address.ToString() -like "*$Pattern*") -or
                           ($_.RecordData.HostNameAlias -and $_.RecordData.HostNameAlias          -like "*$Pattern*")
                       }

            if ($records) {
                Write-Host "`n  [ $zone ]" -ForegroundColor Yellow
                $records | Format-Table HostName, RecordType,
                    @{Label="Data"; Expression={ Get-RecordData $_ }} -AutoSize
            }
        }
        catch {
            Write-Host "  [WARN] Could not search zone ${zone}: $_" -ForegroundColor DarkYellow
        }
    }
}

# ============================================================
#  INTERACTIVE MENU
# ============================================================
function Show-DNSMenu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  +==========================================+" -ForegroundColor Cyan
        Write-Host "  |     Enterprise DNS Automation Utility    |" -ForegroundColor Cyan
        Write-Host "  |     Server : $($script:Config.DnsServer.PadRight(28))|" -ForegroundColor Cyan
        Write-Host "  |     Zones  : $($script:Config.Zones.Count) configured zone(s)              |" -ForegroundColor Cyan
        Write-Host "  +==========================================+" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1]  Add A Record"      -ForegroundColor White
        Write-Host "   [2]  Add CNAME Record"  -ForegroundColor White
        Write-Host "   [3]  Update A Record"   -ForegroundColor White
        Write-Host "   [4]  Delete DNS Record" -ForegroundColor White
        Write-Host "   [5]  View Zone Summary" -ForegroundColor White
        Write-Host "   [6]  Search All Zones"  -ForegroundColor White
        Write-Host "   [Q]  Quit"              -ForegroundColor DarkGray
        Write-Host ""

        $choice = Read-Host "  Select option"

        switch ($choice.ToUpper()) {
            "1" {
                $zone = Select-Zone
                if (-not $zone) { continue }
                $name = Read-Host "  Hostname (without zone)"
                $ip   = Read-Host "  IPv4 Address"
                $ttl  = Read-Host "  TTL in minutes [60]"
                if ([string]::IsNullOrWhiteSpace($ttl)) { $ttl = 60 }
                Add-DNSARecord -Zone $zone -Name $name -IPAddress $ip -TTLMinutes ([int]$ttl)
                Pause
            }
            "2" {
                $zone  = Select-Zone
                if (-not $zone) { continue }
                $name  = Read-Host "  CNAME label (without zone)"
                $alias = Read-Host "  Points to (FQDN)"
                $ttl   = Read-Host "  TTL in minutes [60]"
                if ([string]::IsNullOrWhiteSpace($ttl)) { $ttl = 60 }
                Add-DNSCNameRecord -Zone $zone -Name $name -HostNameAlias $alias -TTLMinutes ([int]$ttl)
                Pause
            }
            "3" {
                $zone  = Select-Zone
                if (-not $zone) { continue }
                $name  = Read-Host "  Hostname to update"
                $newIP = Read-Host "  New IPv4 Address"
                $ttl   = Read-Host "  New TTL in minutes [60]"
                if ([string]::IsNullOrWhiteSpace($ttl)) { $ttl = 60 }
                Update-DNSARecord -Zone $zone -Name $name -NewIPAddress $newIP -TTLMinutes ([int]$ttl)
                Pause
            }
            "4" {
                $zone = Select-Zone
                if (-not $zone) { continue }
                $name = Read-Host "  Record name to delete"
                $type = Read-Host "  Record type [A/CNAME/MX/TXT] (default A)"
                if ([string]::IsNullOrWhiteSpace($type)) { $type = "A" }
                Remove-DNSRecord -Zone $zone -Name $name -RRType $type.ToUpper()
                Pause
            }
            "5" {
                $zone = Select-Zone
                if (-not $zone) { continue }
                Get-DNSZoneSummary -Zone $zone
                Pause
            }
            "6" {
                $pattern = Read-Host "  Search pattern (name or IP fragment)"
                Search-DNSRecord -Pattern $pattern
                Pause
            }
            "Q" { Write-Host "`n  Goodbye.`n" -ForegroundColor Cyan; return }
            default { Write-Host "`n  Invalid option." -ForegroundColor Red; Start-Sleep 1 }
        }
    }
}

function Select-Zone {
    Write-Host "`n  Available zones:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $script:Config.Zones.Count; $i++) {
        Write-Host "   [$($i+1)]  $($script:Config.Zones[$i])"
    }
    $sel = Read-Host "  Select zone number"
    $idx = [int]$sel - 1
    if ($idx -ge 0 -and $idx -lt $script:Config.Zones.Count) {
        return $script:Config.Zones[$idx]
    }
    Write-Host "  Invalid selection." -ForegroundColor Red
    return $null
}

# ============================================================
#  ENTRY POINT
# ============================================================
Write-DNSLog -Level INFO -Message "DNS Automation Utility started by $env:USERNAME on $env:COMPUTERNAME"
Show-DNSMenu
Write-DNSLog -Level INFO -Message "DNS Automation Utility exited by $env:USERNAME"
