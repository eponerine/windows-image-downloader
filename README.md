# Get-WindowsImagesFromAzure.ps1

Download the latest Windows Server 2025 Datacenter Gen2 marketplace image for each requested SKU, then produce a locally expanded, dynamic VHDX for use with a Gen2 Hyper-V VM. By default, the script processes both Core and GUI images.

## TL;DR

From an elevated Windows PowerShell session, after preparing the resource group and output directory (see below), this downloads the Windows Server 2025 Core image (smalldisk) using device-code authentication:

```powershell
.\Get-WindowsImagesFromAzure.ps1 `
	-TenantId '00000000-0000-0000-0000-000000000002' `
	-SubscriptionId '00000000-0000-0000-0000-000000000001' `
	-ResourceGroupName 'example-images-rg' `
	-Location 'eastus' `
	-DiskSizeGB 150 `
	-OutputPath 'C:\VMImages\WindowsServer' `
	-Skus '2025-datacenter-core-g2-smalldisk'
```

Replace the placeholder IDs, resource group, and output path with your own values. The resource group and output directory must already exist. This example uses the script's default Core SKU; the default run without `-Skus` processes both Core and GUI.

## Prerequisites

- Windows and Windows PowerShell 5.1 or later. The script declares `#Requires -RunAsAdministrator`.
- The `Az.Accounts`, `Az.Compute`, and `Az.Resources` modules.
- Hyper-V PowerShell cmdlets, including `Get-VHD`, `Convert-VHD`, `Resize-VHD`, `Mount-VHD`, and `Dismount-VHD`.
- Windows Storage cmdlets used to inspect and grow the mounted disk, including `Get-Disk`, `Set-Disk`, `Update-Disk`, `Get-Partition`, `Get-PartitionSupportedSize`, and `Resize-Partition`.
- BITS (`Start-BitsTransfer`) when AzCopy is not available or its temporary setup is declined or fails.
- An Azure subscription with permission to discover marketplace images, create managed disks, grant and revoke disk access, and delete managed disks. Owner and Contributor will work nicely.
- An existing resource group. The script does not create one. The output directory must also already exist; the default is the current directory.
- Per SKU, roughly 127 GB of local space for the downloaded fixed VHD, plus space for the dynamic VHDX while both files coexist. Actual VHDX file size depends on used data; `DiskSizeGB` is its virtual capacity.

Install the required Az modules for the current user:

```powershell
Install-Module -Name Az.Accounts, Az.Compute, Az.Resources -Repository PSGallery -Scope CurrentUser
```

On supported Windows client editions, enable the Hyper-V management PowerShell feature from an elevated session, then restart if Windows requests it:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All
```

On Windows Server, use the server role-management cmdlet in an elevated session instead:

```powershell
Install-WindowsFeature -Name Hyper-V-PowerShell
```

Availability of Hyper-V management components depends on the Windows edition and installation. BITS is a Windows component; confirm `Start-BitsTransfer` is available if relying on the fallback.

## Prepare Azure and Output Locations

Create the resource group and output directory yourself if they do not already exist. For example, after signing in and selecting the intended subscription:

```powershell
Connect-AzAccount -UseDeviceAuthentication
Set-AzContext -SubscriptionId '00000000-0000-0000-0000-000000000001'
New-AzResourceGroup -Name 'ws2025-images-rg' -Location 'East US'
New-Item -ItemType Directory -Path 'C:\VMImages\WindowsServer2025' -Force
```

If the resource group or output directory already exists, omit the corresponding creation command. The `Location` passed to the script is the Azure marketplace image/disks region.

## Processing Flow

For each SKU, the script:

1. Selects or establishes an Azure context, then selects the requested subscription and optional tenant.
2. Queries marketplace image versions in the requested location and sorts version strings as numeric PowerShell `[version]` values, descending, to choose the latest.
3. Creates a Windows Gen2 (`V2`) Standard_LRS managed disk from that image in the existing resource group.
4. Grants read access to the disk with an eight-hour SAS, then downloads the source VHD.
5. Revokes the SAS after a successful download.
6. Converts the fixed VHD to a dynamic VHDX, then expands the VHDX virtual capacity to `DiskSizeGB`. Conversion happens before expansion.
7. Mounts the VHDX, brings its disk online and writable when needed, updates disk information, and chooses the largest `Basic` partition as the OS partition.
8. Grows that partition to its supported maximum, which also grows NTFS, when contiguous free space permits; then dismounts the VHDX.
9. Attempts SAS and managed-disk cleanup and, after normal completion, deletes the intermediate VHD unless `-KeepFixedVhd` was supplied.

If no free space immediately follows the selected partition, expansion is warned about and skipped; this warning alone does not necessarily fail processing.

## Authentication

When a new sign-in is needed, device-code authentication is the default. `-InteractiveLogin` requests the normal interactive browser/WAM sign-in instead. The script passes `SubscriptionId` and, when supplied, `TenantId` to `Connect-AzAccount`.

The script reuses the current Az context without signing in again when one exists and either no tenant was specified or its tenant matches `TenantId`. A tenant mismatch causes a new sign-in. `-ForceLogin` also causes a new sign-in, even when a context exists. `-InteractiveLogin` only controls the sign-in method if a sign-in is happening; by itself it does not force reauthentication.

After either reusing or creating a context, the script calls `Set-AzContext` for `SubscriptionId` and the optional `TenantId`. Reusing a context does not automatically authenticate again; context selection can fail if the requested subscription is unavailable in that context.

## Parameters

| Parameter | Type | Required | Default | Validation | Purpose |
|---|---|---:|---|---|---|
| `SubscriptionId` | `string` | Yes | None | None declared | Azure subscription used for image discovery and managed-disk operations. |
| `ResourceGroupName` | `string` | Yes | None | None declared | Existing resource group for the temporary managed disks. |
| `Location` | `string` | Yes | None | None declared | Azure region used to find the marketplace image and create the disk. |
| `DiskSizeGB` | `int` | Yes | None | 128–2040 inclusive | Requested VHDX virtual capacity in GB. This is not necessarily the dynamic VHDX's physical file size. |
| `TenantId` | `string` | No | None | None declared | Optional tenant passed to sign-in and final context selection. |
| `InteractiveLogin` | `switch` | No | Off | None declared | Use interactive sign-in instead of device code when the script needs to sign in. |
| `ForceLogin` | `switch` | No | Off | None declared | Sign in again even if an Az context already exists. |
| `OutputPath` | `string` | No | Current directory | None declared | Existing local directory for VHD and VHDX files. |
| `PublisherName` | `string` | No | `MicrosoftWindowsServer` | None declared | Marketplace image publisher. |
| `Offer` | `string` | No | `WindowsServer` | None declared | Marketplace image offer; also used in output filenames. |
| `Skus` | `string[]` | No | `2025-datacenter-core-g2`, `2025-datacenter-g2` | None declared | One or more marketplace SKUs to process. |
| `KeepAzureDisk` | `switch` | No | Off | None declared | Do not attempt to delete each temporary Azure managed disk after processing. |
| `KeepFixedVhd` | `switch` | No | Off | None declared | Keep the downloaded fixed VHD after successful processing. |

Custom SKUs must be compatible with the script's Windows Gen2 disk and largest-Basic-partition assumptions.

## Examples

All examples use placeholder subscription and tenant GUIDs. Replace them with IDs you can access. The resource group and output path must already exist unless you run the preparation commands above.

Both default SKUs, using device-code authentication by default:

```powershell
.\Get-WindowsImagesFromAzure.ps1 `
	-SubscriptionId '00000000-0000-0000-0000-000000000001' `
	-ResourceGroupName 'ws2025-images-rg' `
	-Location 'East US' `
	-DiskSizeGB 256
```

Explicit tenant and subscription:

```powershell
.\Get-WindowsImagesFromAzure.ps1 `
	-SubscriptionId '00000000-0000-0000-0000-000000000001' `
	-TenantId '00000000-0000-0000-0000-000000000002' `
	-ResourceGroupName 'ws2025-images-rg' `
	-Location 'East US' `
	-DiskSizeGB 256
```

Interactive sign-in and forced reauthentication:

```powershell
.\Get-WindowsImagesFromAzure.ps1 `
	-SubscriptionId '00000000-0000-0000-0000-000000000001' `
	-TenantId '00000000-0000-0000-0000-000000000002' `
	-ResourceGroupName 'ws2025-images-rg' `
	-Location 'East US' `
	-DiskSizeGB 256 `
	-InteractiveLogin `
	-ForceLogin
```

Core only:

```powershell
.\Get-WindowsImagesFromAzure.ps1 `
	-SubscriptionId '00000000-0000-0000-0000-000000000001' `
	-ResourceGroupName 'ws2025-images-rg' `
	-Location 'East US' `
	-DiskSizeGB 256 `
	-Skus '2025-datacenter-core-g2'
```

GUI only:

```powershell
.\Get-WindowsImagesFromAzure.ps1 `
	-SubscriptionId '00000000-0000-0000-0000-000000000001' `
	-ResourceGroupName 'ws2025-images-rg' `
	-Location 'East US' `
	-DiskSizeGB 256 `
	-Skus '2025-datacenter-g2'
```

Custom output directory and disk capacity:

```powershell
.\Get-WindowsImagesFromAzure.ps1 `
	-SubscriptionId '00000000-0000-0000-0000-000000000001' `
	-ResourceGroupName 'ws2025-images-rg' `
	-Location 'East US' `
	-DiskSizeGB 512 `
	-OutputPath 'C:\VMImages\WindowsServer2025'
```

Keep the Azure managed disk or the original fixed VHD (use either or both switches):

```powershell
.\Get-WindowsImagesFromAzure.ps1 `
	-SubscriptionId '00000000-0000-0000-0000-000000000001' `
	-ResourceGroupName 'ws2025-images-rg' `
	-Location 'East US' `
	-DiskSizeGB 256 `
	-KeepAzureDisk `
	-KeepFixedVhd
```

## Download Behavior

The script first uses `azcopy` if it is already in `PATH`. Otherwise, it prompts once whether to download AzCopy from [https://aka.ms/downloadazcopy-v10-windows](https://aka.ms/downloadazcopy-v10-windows). If accepted, it streams the ZIP through .NET `HttpClient` with a five-minute timeout, extracts it into a uniquely named directory under the system temporary directory, and invokes the discovered `azcopy.exe` from there. That executable is reused for subsequent SKUs in the same run; `PATH` is not modified. The script does not remove this temporary directory or ZIP, so remove them manually when no longer needed.

Declining the prompt or an AzCopy setup failure falls back to `Start-BitsTransfer` for the VHD. A nonzero exit from an AzCopy VHD transfer is an error, not a trigger for BITS fallback. No specific transfer speed, automatic retry, or resumable-download behavior is promised.

## Output and Cleanup

For the default offer and SKUs, the output patterns are:

- Fixed source: `WindowsServer-<sku>-<version>.vhd`
- Expanded dynamic VHDX: `WindowsServer-<sku>-<version>-<DiskSizeGB>GB.vhdx`

The actual offer, SKU, selected image version, and requested capacity form the filenames. Before downloading, an existing matching VHD is deleted. Before conversion, an existing matching VHDX is deleted. These files are overwritten by the next run; a failed download or conversion may leave a partial file behind.

After a SAS has been issued, the script revokes it after a successful download and attempts revocation again during cleanup if needed. Unless `-KeepAzureDisk` is used, it attempts to delete the Azure managed disk in the `finally` cleanup block. Azure cleanup can fail, and abrupt termination can bypass cleanup. Managed disks continue to incur Azure charges until deleted.

The mounted VHDX is dismounted in a `finally` block around disk expansion. The source VHD is deleted only when processing reaches normal completion, a VHDX exists, and `-KeepFixedVhd` is not set. Conversion or expansion failure retains the source VHD; failed conversion can also leave a partial VHDX. A partition-growth warning can still be followed by normal completion and source-VHD deletion.

## Limitations, Costs, and Security

- These are GPT/UEFI Gen2 images and require Gen2 Hyper-V VMs. This script only creates image files; it does not create VMs.
- Partition growth needs contiguous free space after the selected largest Basic partition. A later partition, such as a recovery partition, can prevent growth; the script does not relocate partitions.
- Azure managed disks incur charges until deleted, especially when using `-KeepAzureDisk` or when interrupted cleanup leaves a disk behind.
- SAS URLs are credentials. Do not publish them in logs, terminal captures, issues, or support requests.
- Marketplace access, licensing, Azure policy, network access, and local permissions can affect execution.
- Cleanup is best-effort and is not guaranteed after abrupt termination.
- Custom SKUs must suit the script's Windows Gen2 assumptions.

## Troubleshooting

- **Missing module or cmdlet:** Install the three Az modules and the Hyper-V PowerShell management feature. Check that `Get-Module -ListAvailable Az.Accounts, Az.Compute, Az.Resources` and `Get-Command Get-VHD, Convert-VHD, Resize-VHD, Mount-VHD, Start-BitsTransfer` return the expected commands.
- **Elevation or Hyper-V errors:** Start Windows PowerShell as Administrator. Confirm the Windows edition supports the Hyper-V management feature and that any required restart has completed.
- **Wrong tenant or subscription:** Check the IDs and access. Use `-TenantId` to choose a tenant, `-ForceLogin` to sign in again, and `-InteractiveLogin` to select interactive authentication. The final context selection still needs access to the requested subscription.
- **Resource group or output path not found:** Create the resource group and directory manually before running the script. It does not create either one.
- **Azure permission or policy failure:** Verify image discovery and managed-disk create, grant-access, revoke-access, and delete permissions, plus marketplace terms/access and applicable Azure policy.
- **AzCopy ZIP download or extraction failure:** Check access to `aka.ms`, local temp-directory permissions, available disk space, and ZIP extraction support. Setup failure falls back to BITS. BITS may also be unavailable or blocked by network policy.
- **VHD download failure or expired SAS:** The SAS is valid for eight hours. Check network access and the reported AzCopy/BITS error. Retry the script if appropriate; it does not promise transfer retries or resume. A failed download may leave a partial VHD.
- **Insufficient local space:** Free space for the fixed source VHD and the VHDX at the same time. Keep the source VHD until you have inspected a failed or incomplete result.
- **Partition did not grow:** Read the warning and inspect the partition layout. Free space must be contiguous after the selected largest Basic partition; the script does not move another partition.
- **File locked or cannot be overwritten/deleted:** Close tools using the VHD/VHDX, ensure it is dismounted, and check local permissions. Existing matching outputs are deleted before replacement.
- **Interrupted run:** Preserve remaining VHD/VHDX files and logs for investigation. Check Azure for managed disks left behind and remove them when safe; do not assume cleanup ran.
