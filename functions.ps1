function Test-RotaConnections {}
function Get-RotaScreenshotsForProcessing {
    param (
        $storage_accountKey = ( Get-AzAutomationVariable -Name storage_accountKey ),
        $storage_accountName = ( Get-AzAutomationVariable -Name storage_accountName ),
        $storage_fileshareName = ( Get-AzAutomationVariable -Name storage_fileshareName ),
        $storage_blobContainerName = ( Get-AzAutomationVariable -Name storage_blobContainerName ),
        $storage_accountContext = ( New-AzStorageContext -StorageAccountName $storage_accountName -StorageAccountKey $storage_accountKey ),
        [bool]$listOnly = $false
    )
    try {
        # Move everything from File share into blob, Document Intelligence needs blobs
        $currentFiles = Get-AzStorageFile -ShareName $storage_fileshareName -context $storage_accountContext
        foreach ($file in $currentFiles.Name) {
            Start-AzStorageBlobCopy -Context $storage_accountContext -SrcShareName $storage_fileshareName -DestContext $storage_accountContext -DestContainer $storage_blobContainerName -DestBlob $file -SrcFilePath $file -Force | Out-Null
        }

        $blobs = Get-AzStorageBlob -Container $storage_blobContainerName -Context $storage_accountContext

        if ($blobs.Count -gt 0) {
            $return = $blobs.BlobBaseClient.Uri.AbsoluteUri
        }
        else {
            Write-Error "No blobs returned"
        }
    }
    catch {
        $return = @{
            status = "failed"
            value  = "Unable to get any blobs to process"
        }
    }
    return $return
}
function Submit-RotaScreenshotForProcessing {}
function Get-RotaProcessedScreenshot {}
function Get-RotaListOfShifts {}
function Get-RotaCurrentGoogleCalendar {}
function Add-RotaGoogleCalendarEntry {}
function Invoke-RotaCleanup {}