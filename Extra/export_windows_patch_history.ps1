param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$ScanHost = "",
    [string]$ScanDateTime = "",
    [string]$ScanMode = "",
    [string]$Drive = ""
)

$ErrorActionPreference = "Stop"

function Get-KbFromText {
    param([string]$Text)

    $match = [regex]::Match([string]$Text, 'KB\d+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Value.ToUpperInvariant()
    }

    return ""
}

function Get-OperationText {
    param([int]$Code)

    switch ($Code) {
        1 { return "Install" }
        2 { return "Uninstall" }
        3 { return "Other" }
        default { return "Unknown" }
    }
}

function Get-ResultText {
    param([int]$Code)

    switch ($Code) {
        0 { return "NotStarted" }
        1 { return "InProgress" }
        2 { return "Succeeded" }
        3 { return "SucceededWithErrors" }
        4 { return "Failed" }
        5 { return "Aborted" }
        default { return "Unknown" }
    }
}

function Get-ServerSelectionText {
    param([int]$Code)

    switch ($Code) {
        0 { return "Default" }
        1 { return "ManagedServer" }
        2 { return "WindowsUpdate" }
        3 { return "Other" }
        default { return "Unknown" }
    }
}

function Get-ProductComponent {
    param(
        [string]$Title,
        [string]$Description,
        [string]$Category
    )

    $text = "{0} {1} {2}" -f $Title, $Description, $Category

    switch -Regex ($text) {
        'Windows Security platform|KB5007651|Defender' { return "Windows Defender / Security Platform" }
        'Visual C\+\+' { return "Visual C++ Redistributable" }
        '\.NET Framework' { return ".NET Framework" }
        '\.NET ' { return ".NET" }
        'Windows 11|Windows 10|mise a jour cumulative pour Windows|Mise a jour cumulative pour Windows|Cumulative Update for Windows' { return "Windows" }
        'servicing stack' { return "Windows Servicing Stack" }
        'logiciels malveillants|Malicious Software Removal' { return "MSRT" }
        default {
            if ($Category) {
                return $Category
            }

            return "Unknown"
        }
    }
}

function Get-SeverityOrType {
    param(
        [string]$Title,
        [string]$Description,
        [string]$Category
    )

    $text = "{0} {1} {2}" -f $Title, $Description, $Category

    switch -Regex ($text) {
        'Security Update|Mise a jour de securite|Mise a jour de sécurité' { return "Security Update" }
        'servicing stack' { return "Servicing Stack" }
        'Apercu|Aperçu|Preview|Preversion|Preversion' { return "Preview" }
        'cumulative' { return "Cumulative Update" }
        'Windows Security platform|KB5007651|Defender' { return "Security Platform Update" }
        'logiciels malveillants|Malicious Software Removal' { return "Removal Tool" }
        default { return "Update" }
    }
}

function Get-AffectedVersionAfter {
    param(
        [string]$Title,
        [string]$Description
    )

    $text = "{0} {1}" -f $Title, $Description
    $patterns = @(
        'version\s+\d+\.\d+\.\d+\.\d+',
        'Windows\s+(?:10|11)\s+Version\s+[0-9A-Za-z]+',
        '\.NET(?:\s+Framework)?\s+\d+(?:\.\d+){1,3}'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return $match.Value.Trim()
        }
    }

    return ""
}

function Get-PatchSource {
    param(
        $Entry,
        [hashtable]$ServiceMap
    )

    $serviceId = ""
    if ($Entry.ServiceID) {
        $serviceId = $Entry.ServiceID.ToLowerInvariant()
    }

    if ($serviceId -and $ServiceMap.ContainsKey($serviceId)) {
        return $ServiceMap[$serviceId]
    }

    switch ([int]$Entry.ServerSelection) {
        1 { return "WSUS / Managed Server" }
        2 { return "Windows Update" }
        3 {
            if ($Entry.ClientApplicationID -match 'Manual|Interactive|User') {
                return "Manual / Other"
            }

            return "Other Service"
        }
        default { return "Default" }
    }
}

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$machineBuild = "{0}.{1}" -f $cv.CurrentBuild, $cv.UBR
$machineVersion = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }

$serviceMap = @{}
try {
    $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
    foreach ($service in $serviceManager.Services) {
        if ($service.ServiceID) {
            $serviceMap[$service.ServiceID.ToLowerInvariant()] = $service.Name
        }
    }
} catch {
}

$qfeByKb = @{}
try {
    Get-CimInstance Win32_QuickFixEngineering | ForEach-Object {
        if ($_.HotFixID) {
            $qfeByKb[$_.HotFixID.ToUpperInvariant()] = $_
        }
    }
} catch {
}

$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$historyCount = $searcher.GetTotalHistoryCount()

$rows = @(
    $searcher.QueryHistory(0, $historyCount) |
        Where-Object { $_.Title -match 'KB[0-9]+' } |
        Sort-Object Date -Descending |
        ForEach-Object {
            $entry = $_
            $kb = Get-KbFromText $entry.Title
            $categories = @($entry.Categories | ForEach-Object { $_.Name } | Where-Object { $_ }) -join '; '
            $installedBy = ""

            if ($kb -and $qfeByKb.ContainsKey($kb)) {
                $installedBy = [string]$qfeByKb[$kb].InstalledBy
            }

            [pscustomobject]@{
                ScanHost             = $ScanHost
                ScanDateTime         = $ScanDateTime
                ScanMode             = $ScanMode
                Drive                = $Drive
                AppliedDate          = $entry.Date.ToString('yyyy-MM-dd HH:mm:ss')
                KB                   = $kb
                Title                = [string]$entry.Title
                Description          = [string]$entry.Description
                Category             = $categories
                ProductComponent     = Get-ProductComponent $entry.Title $entry.Description $categories
                SeverityOrType       = Get-SeverityOrType $entry.Title $entry.Description $categories
                Operation            = [int]$entry.Operation
                OperationText        = Get-OperationText $entry.Operation
                ResultCode           = [int]$entry.ResultCode
                ResultText           = Get-ResultText $entry.ResultCode
                Source               = Get-PatchSource $entry $serviceMap
                ServiceName          = if ($entry.ServiceID -and $serviceMap.ContainsKey($entry.ServiceID.ToLowerInvariant())) { $serviceMap[$entry.ServiceID.ToLowerInvariant()] } else { "" }
                ServiceID            = [string]$entry.ServiceID
                ServerSelection      = [int]$entry.ServerSelection
                ServerSelectionText  = Get-ServerSelectionText $entry.ServerSelection
                ClientApplicationID  = [string]$entry.ClientApplicationID
                InstalledBy          = $installedBy
                VersionBefore        = ""
                VersionAfter         = Get-AffectedVersionAfter $entry.Title $entry.Description
                MachineProductName   = [string]$cv.ProductName
                MachineDisplayVersion= [string]$machineVersion
                MachineBuildAtExport = [string]$machineBuild
                SupportUrl           = [string]$entry.SupportUrl
            }
        }
)

$columns = @(
    'ScanHost',
    'ScanDateTime',
    'ScanMode',
    'Drive',
    'AppliedDate',
    'KB',
    'Title',
    'Description',
    'Category',
    'ProductComponent',
    'SeverityOrType',
    'Operation',
    'OperationText',
    'ResultCode',
    'ResultText',
    'Source',
    'ServiceName',
    'ServiceID',
    'ServerSelection',
    'ServerSelectionText',
    'ClientApplicationID',
    'InstalledBy',
    'VersionBefore',
    'VersionAfter',
    'MachineProductName',
    'MachineDisplayVersion',
    'MachineBuildAtExport',
    'SupportUrl'
)

if ($rows.Count -eq 0) {
    $header = ([pscustomobject]([ordered]@{
        ScanHost              = ''
        ScanDateTime          = ''
        ScanMode              = ''
        Drive                 = ''
        AppliedDate           = ''
        KB                    = ''
        Title                 = ''
        Description           = ''
        Category              = ''
        ProductComponent      = ''
        SeverityOrType        = ''
        Operation             = ''
        OperationText         = ''
        ResultCode            = ''
        ResultText            = ''
        Source                = ''
        ServiceName           = ''
        ServiceID             = ''
        ServerSelection       = ''
        ServerSelectionText   = ''
        ClientApplicationID   = ''
        InstalledBy           = ''
        VersionBefore         = ''
        VersionAfter          = ''
        MachineProductName    = ''
        MachineDisplayVersion = ''
        MachineBuildAtExport  = ''
        SupportUrl            = ''
    }) | ConvertTo-Csv -NoTypeInformation)[0]

    Set-Content -Path $OutputPath -Value $header -Encoding UTF8
    exit 0
}

$rows | Select-Object $columns | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
