function Test-RotaConnections {}
function Get-RotaScreenshotsForProcessing {
    param (
        $storage_accountKey = ( Get-AutomationVariable -Name "storage_accountKey" ),
        $storage_accountName = ( Get-AutomationVariable -Name "storage_accountName" ),
        $storage_fileshareName = ( Get-AutomationVariable -Name "storage_fileshareName" ),
        $storage_blobContainerName = ( Get-AutomationVariable -Name "storage_blobContainerName" ),
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
function Submit-RotaScreenshotForProcessing {
    param (
        $image_uri,
        $di_key = ( Get-AutomationVariable -Name "di_key" ),
        $di_endpoint_version = ( Get-AutomationVariable -Name "di_endpoint_version" ),
        $di_model_name = ( Get-AutomationVariable -Name "di_model_name" ),
        $di_endpoint_uri = ( Get-AutomationVariable -Name "di_endpoint_uri" ),
        $headers = @{
            'Content-Type'              = 'application/json'
            'Ocp-Apim-Subscription-Key' = $($di_key)
        },
        $body = "{'urlSource': '$image_uri'}",
        $di_uri = $di_endpoint_uri + "/formrecognizer/documentModels/$($di_model_name):analyze?api-version=$di_endpoint_version",
        $tierF0delay = 8
    )

    try {
        $response = Invoke-WebRequest -Uri $di_uri -Method Post -Headers $headers -Body $body
        if ($response.StatusCode -eq "202") {
            [bool]$return_ok = $true
            $return_value = $response.Headers.'Operation-Location'
            Start-Sleep -Seconds $tierF0delay
            Write-Verbose "Waiting for $tierF0delay seconds as part of F0 limits."
        }
    }
    catch {
        $return_ok = $false
        $return_value = "[Submit-RotaScreenshotForProcessing] did not get http/202, got $($response.StatusCode)"
    }
    finally {
        $return = @{
            status = $return_ok
            value  = $return_value
        }
    }
    return $return
function Get-RotaProcessedScreenshot {}
function Get-RotaListOfShifts {}
function Get-RotaCurrentGoogleCalendar {}
function Add-RotaGoogleCalendarEntry {}
function Invoke-RotaCleanup {}