#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules Az.Accounts, Az.Compute, Az.Resources

<#
.SYNOPSIS
  Downloads the latest Windows Server 2025 Datacenter (Core + GUI, Gen2) marketplace images
  as VHDX files, expanded to a size you choose.

.DESCRIPTION
  For each SKU:
    1. Finds the highest version (Major.Minor.Date, sorted as [version])
    2. Creates a managed disk from the marketplace image in your subscription/RG
    3. Grants read access (SAS) and downloads the VHD
    4. Converts the downloaded VHD to a dynamic VHDX
    5. Resizes the VHDX, mounts it, grows the OS partition + NTFS, then dismounts
    6. Cleans up the SAS, the Azure disk and the intermediate VHD (optional)

.NOTES
  Requires the Hyper-V PowerShell module (Mount-VHD, Resize-VHD, Convert-VHD):
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell
    AzCopy is used if found in PATH (much faster); otherwise offers a temporary download.
    If declined or setup fails, falls back to BITS.
    Free disk space needed per SKU, which can be up to 127 GB.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $Location,

    # Target size of the OS disk. Image is ~127 GB. VHD format max is 2040 GB.
    [Parameter(Mandatory)] [ValidateRange(128, 2040)] [int] $DiskSizeGB,

    # Authentication
    [string] $TenantId,                 # optional, recommended if you have access to several tenants
    [switch] $InteractiveLogin,         # use the normal browser/WAM sign-in instead of device code
    [switch] $ForceLogin,               # sign in again even if an Az context already exists

    [string]   $OutputPath    = (Get-Location).Path,
    [string]   $PublisherName = 'MicrosoftWindowsServer',
    [string]   $Offer         = 'WindowsServer',
    [string[]] $Skus          = @('2025-datacenter-core-g2', '2025-datacenter-g2'),

    [switch] $KeepAzureDisk,
    [switch] $KeepFixedVhd
)

$ErrorActionPreference = 'Stop'
$script:AzCopyChecked = $false
$script:AzCopyPath = $null

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Get-LatestImage {
    param($Location, $Publisher, $Offer, $Sku)

    $versions = Get-AzVMImage -Location $Location -PublisherName $Publisher -Offer $Offer -Skus $Sku
    if (-not $versions) { throw "No images found for $Publisher/$Offer/$Sku in $Location" }

    # Sort as System.Version (numeric per component), NOT as string.
    # 26100.35370.260206 -> Major=26100, Minor=35370, Build=260206
    $versions |
        Sort-Object -Property { [version]$_.Version } -Descending |
        Select-Object -First 1
}

function Save-HttpFile {
    param([uri] $Uri, [string] $Destination, [int] $TimeoutSeconds = 300)

    Add-Type -AssemblyName System.Net.Http
    $client = $null
    $cancellation = $null
    $response = $null
    $sourceStream = $null
    $destinationStream = $null
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $cancellation = New-Object System.Threading.CancellationTokenSource
        $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
        $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $sourceStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $destinationStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 81920
        while (($bytesRead = $sourceStream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
            $destinationStream.WriteAsync($buffer, 0, $bytesRead, $cancellation.Token).GetAwaiter().GetResult() | Out-Null
        }
    }
    finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($cancellation) { $cancellation.Dispose() }
    }
}

function Get-AzCopyPath {
    if ($script:AzCopyChecked) { return $script:AzCopyPath }
    $script:AzCopyChecked = $true
    $azcopy = Get-Command azcopy -ErrorAction SilentlyContinue
    if ($azcopy) {
        $script:AzCopyPath = $azcopy.Source
        return $script:AzCopyPath
    }

    $answer = Read-Host 'AzCopy is not in PATH. Download it to a temporary directory? [y/N]'
    if ($answer.Trim() -notmatch '^(y|yes)$') { return }

    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('AzCopy-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null
        $zipPath = Join-Path $tempDirectory 'azcopy.zip'
        Write-Host '  Downloading AzCopy...'
        Save-HttpFile -Uri 'https://aka.ms/downloadazcopy-v10-windows' -Destination $zipPath
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tempDirectory -ErrorAction Stop
        $executable = Get-ChildItem -LiteralPath $tempDirectory -Filter 'azcopy.exe' -File -Recurse -ErrorAction Stop |
                      Select-Object -First 1
        if (-not $executable) { throw 'The downloaded archive does not contain azcopy.exe.' }
        $script:AzCopyPath = $executable.FullName
        return $script:AzCopyPath
    }
    catch {
        Write-Warning "Could not set up temporary AzCopy: $($_.Exception.Message). Falling back to BITS."
    }
}

function Save-DiskVhd {
    param([string] $SasUri, [string] $Destination)

    $azcopyPath = Get-AzCopyPath
    if ($azcopyPath) {
        Write-Host "  Downloading with AzCopy..."
        & $azcopyPath copy $SasUri $Destination --output-level essential
        if ($LASTEXITCODE -ne 0) { throw "AzCopy failed with exit code $LASTEXITCODE" }
    }
    else {
        Write-Warning "AzCopy unavailable - falling back to BITS (slower)."
        Start-BitsTransfer -Source $SasUri -Destination $Destination -DisplayName 'WS2025 VHD'
    }
}

function Expand-VhdAndFileSystem {
    param([string] $VhdPath, [int] $SizeGB)

    $targetBytes  = [uint64]$SizeGB * 1GB
    $currentBytes = (Get-VHD -Path $VhdPath).Size

    if ($targetBytes -gt $currentBytes) {
        Write-Host "  Resizing VHD from $([math]::Round($currentBytes/1GB,2)) GB to $SizeGB GB..."
        Resize-VHD -Path $VhdPath -SizeBytes $targetBytes
    }
    else {
        Write-Warning "  Requested size ($SizeGB GB) is not larger than current VHD size; skipping VHD resize."
    }

    Write-Host "  Mounting VHD..."
    Mount-VHD -Path $VhdPath -NoDriveLetter:$false | Out-Null
    try {
        $diskNumber = (Get-VHD -Path $VhdPath).DiskNumber
        $disk = Get-Disk -Number $diskNumber
        if ($disk.IsOffline)  { Set-Disk -Number $diskNumber -IsOffline  $false }
        if ($disk.IsReadOnly) { Set-Disk -Number $diskNumber -IsReadOnly $false }
        Update-Disk -Number $diskNumber

        # OS partition = largest basic data partition on the disk
        $osPart = Get-Partition -DiskNumber $diskNumber |
                  Where-Object Type -eq 'Basic' |
                  Sort-Object Size -Descending |
                  Select-Object -First 1
        if (-not $osPart) { throw "Could not find the OS partition on disk $diskNumber" }

        $supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $osPart.PartitionNumber
        if ($supported.SizeMax -gt $osPart.Size) {
            Write-Host "  Extending partition $($osPart.PartitionNumber) to $([math]::Round($supported.SizeMax/1GB,2)) GB (partition + NTFS)..."
            Resize-Partition -DiskNumber $diskNumber -PartitionNumber $osPart.PartitionNumber -Size $supported.SizeMax
        }
        else {
            Write-Warning "  Partition cannot grow (no contiguous free space after it - is another partition behind it?)."
        }
    }
    finally {
        Write-Host "  Dismounting VHD..."
        Dismount-VHD -Path $VhdPath
    }
}
# ----------------------------------------------------------------------------
# Connect (device code by default)
# ----------------------------------------------------------------------------
$ctx = Get-AzContext
$needLogin = $ForceLogin -or -not $ctx -or
             ($TenantId -and $ctx.Tenant.Id -ne $TenantId)

if ($needLogin) {
    $connect = @{ ErrorAction = 'Stop'; Subscription = $SubscriptionId }
    if ($TenantId) { $connect.Tenant = $TenantId }

    if ($InteractiveLogin) {
        Write-Host "Signing in to Azure (interactive)..."
    }
    else {
        Write-Host "Signing in to Azure using device code..."
        $connect.UseDeviceAuthentication = $true
    }

    Connect-AzAccount @connect | Out-Null
}
else {
    Write-Host "Using existing Az context: $($ctx.Account.Id) (tenant $($ctx.Tenant.Id))"
}

$ctxParams = @{ SubscriptionId = $SubscriptionId }
if ($TenantId) { $ctxParams.Tenant = $TenantId }
Set-AzContext @ctxParams | Out-Null
Write-Host "Subscription: $((Get-AzContext).Subscription.Name)"

# ----------------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------------
foreach ($sku in $Skus) {
    Write-Host "`n=== $sku ===" -ForegroundColor Cyan

    $image = Get-LatestImage -Location $Location -Publisher $PublisherName -Offer $Offer -Sku $sku
    Write-Host "  Latest version: $($image.Version)"

    $baseName  = "$Offer-$sku-$($image.Version)"
    $diskName  = ($baseName -replace '[^a-zA-Z0-9_\-\.]', '-')
    $vhdPath   = Join-Path $OutputPath "$baseName.vhd"
    $vhdxPath  = Join-Path $OutputPath "$baseName-$($DiskSizeGB)GB.vhdx"
    $sasIssued = $false
    $vhdxComplete = $false

    try {
        # 1. Create managed disk from marketplace image
        Write-Host "  Creating managed disk '$diskName'..."
        $diskConfig = New-AzDiskConfig -Location $Location -CreateOption FromImage -OsType Windows `
                        -HyperVGeneration V2 -SkuName Standard_LRS
        $diskConfig = Set-AzDiskImageReference -Disk $diskConfig -Id $image.Id
        $disk = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Disk $diskConfig

        # 2. Generate SAS (8 hours)
        Write-Host "  Granting read access (SAS)..."
        $access    = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName `
                        -Access Read -DurationInSecond 28800
        $sasIssued = $true

        # 3. Download
        if (Test-Path $vhdPath) { Remove-Item $vhdPath -Force }
        Save-DiskVhd -SasUri $access.AccessSAS -Destination $vhdPath

        Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName | Out-Null
        $sasIssued = $false

        # 4. Convert to VHDX (dynamic)
        Write-Host "  Converting to VHDX: $vhdxPath"
        if (Test-Path $vhdxPath) { Remove-Item $vhdxPath -Force }
        Convert-VHD -Path $vhdPath -DestinationPath $vhdxPath -VHDType Dynamic

        # 5. Expand VHDX, mount, grow partition/file system
        Expand-VhdAndFileSystem -VhdPath $vhdxPath -SizeGB $DiskSizeGB
        $vhdxComplete = $true

        Write-Host "  Done: $vhdxPath" -ForegroundColor Green
    }
    finally {
        if ($sasIssued) {
            Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName -ErrorAction SilentlyContinue | Out-Null
        }
        if (-not $KeepAzureDisk) {
            Write-Host "  Removing Azure disk '$diskName'..."
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Force -ErrorAction SilentlyContinue | Out-Null
        }
        if ($vhdxComplete -and -not $KeepFixedVhd -and (Test-Path $vhdxPath) -and (Test-Path $vhdPath)) {
            Remove-Item $vhdPath -Force
        }
    }
}