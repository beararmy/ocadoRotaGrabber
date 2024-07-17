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
}
function Get-ProcessedRotaScreenshot {
    param (
        $processed_uri,
        $di_key = ( Get-AutomationVariable -Name "di_key" ),
        $waitBetweenRetries = 5,
        $headers = @{
            'Ocp-Apim-Subscription-Key' = $($di_key)
        }
    )

    $response = Invoke-WebRequest -Uri $processed_uri -Method Get -Headers $headers

    while (($response.Content | ConvertFrom-json).status -eq 'running') {

        if ($waitBetweenRetries -lt [convert]::ToInt32($response.Headers.'Retry-After', 10)) {
            [int]$PlatformRetryDuration = [convert]::ToInt32($response.Headers.'Retry-After', 10)
            Write-Verbose "Retry of $waitBetweenRetries too short, using azure platform Retry-After of $PlatformRetryDuration"
            $waitBetweenRetries = $PlatformRetryDuration
        }

        Write-Verbose "Still running, waiting for $waitBetweenRetries seconds"
        Start-Sleep -Seconds $waitBetweenRetries
        $response = Invoke-WebRequest -Uri $processed_uri -Method Get -Headers $headers
    }

    if (($response.Content | ConvertFrom-json).status -ne "succeeded" ) {
        Write-Error -ErrorId -9 -Message "Something went from, processing didn't meet succeeded"
    }

    return $response.Content
}
function Get-RotaListOfShifts {
    #todo: really need to build in handling years, when we get to jan 2025 it'll just think that's 2024.
    param (
        $di_processed_json,
        $freshrun = $true,
        $show_only_working = $false
    )
    $di_date_field = ($di_processed_json | ConvertFrom-Json).analyzeResult.documents.fields.'month year'.content
    $calendar_month = Get-Date ($di_date_field)
    $di_weekday_names = ("wk1-d1", "wk1-d2", "wk1-d3", "wk1-d4", "wk1-d5", "wk1-d6", "wk1-d7", "wk2-d1", "wk2-d2", "wk2-d3", "wk2-d4", "wk2-d5", "wk2-d6", "wk2-d7", "wk3-d1", "wk3-d2", "wk3-d3", "wk3-d4", "wk3-d5", "wk3-d6", "wk3-d7", "wk4-d1", "wk4-d2", "wk4-d3", "wk4-d4", "wk4-d5", "wk4-d6", "wk4-d7", "wk5-d1", "wk5-d2", "wk5-d3", "wk5-d4", "wk5-d5", "wk5-d6", "wk5-d7", "wk6-d1", "wk6-d2", "wk6-d3", "wk6-d4", "wk6-d5", "wk6-d6", "wk6-d7")
    $object = @()
    $inside_correct_month = $false

    foreach ($weekday in $di_weekday_names) {
        if ( -not (($di_processed_json | ConvertFrom-Json).analyzeResult.documents.fields.$($weekday).valueString)) {
            $test = ""
        }
        else {
            $test = ($di_processed_json | ConvertFrom-Json).analyzeResult.documents.fields.$($weekday).valueString
        }
        $start, $finish, $date = $test.Split(" ")

        # Get rid of any months that have 6 or 5 weeks and we've returned nulls.
        if ($test.Length -eq 0) {
            Continue
        }
        # Set var to false to catch when we've fully cycled the main month
        elseif ($date -eq 1 -or $test -eq 1 -and $true -eq $inside_correct_month) {
            $inside_correct_month = $false
            Continue
        }
        # Set var to true when we get inside our desired month
        elseif ($date -eq 1 -or $test -eq 1 -and $false -eq $inside_correct_month) {
            $inside_correct_month = $true
        }

        # Deal with any days we're not working, ie we only returned the day of the month
        if ($true -eq $inside_correct_month -and $true -ne $show_only_working -and $test.Length -lt 5) {
            # $date = $test
            $calendar_day = $calendar_month.AddDays(($test - 1))

            $object += @{date = $calendar_day; shift_working = $false; shift_start = "na"; shift_end = "na" }
        }
        # Deal with days of the month that we're working
        elseif ($true -eq $inside_correct_month -and $test.Length -gt 5) {
            $start, $finish, $date = $test.Split(" ")
            $calendar_day = $calendar_month.AddDays(($date - 1))
            $start_h, $start_m = $start.Split(":")
            $finish_h, $finish_m = $finish.Split(":")
            $calendar_start_fulldate = $calendar_day.AddHours($start_h).AddMinutes($start_m)
            $calendar_end_fulldate = $calendar_day.AddHours($finish_h).AddMinutes($finish_m)
            $object += @{date = $calendar_day; shift_working = $true; shift_start = $calendar_start_fulldate; shift_end = $calendar_end_fulldate }
        }
    }
    return $object
}
function Update-RotaGoogleAuth {
    #todo: this is ugly and takes far too long.
    #todo: if I trust the timeout, why even test it?
    param (
        $goog_current_access_token = ( Get-AutomationVariable -Name goog_current_access_token ),
        $goog_current_access_token_expiry = ( Get-AutomationVariable -Name goog_current_access_token_expiry ),
        $goog_client_secret = ( Get-AutomationVariable -Name goog_client_secret ),
        $goog_login_test_uri = ( Get-AutomationVariable -Name goog_login_test_uri ),
        $goog_refresh_token = ( Get-AutomationVariable -Name goog_refresh_token ),
        $goog_client_id = ( Get-AutomationVariable -Name goog_client_id ),
        $goog_oauth_uri = ( Get-AutomationVariable -Name goog_oauth_uri ),
        $headers = @{
            Authorization = "Bearer $goog_current_access_token"
        },
        $refreshTokenParams = @{
            client_id     = $goog_client_id
            client_secret = $goog_client_secret
            refresh_token = $goog_refresh_token
            grant_type    = "refresh_token"
        }
    )
    try {
        if ((Get-Date($goog_current_access_token_expiry)) -gt (Get-Date)) {
            # $result = (Invoke-WebRequest -Method Get -Headers $headers -Uri $goog_login_test_uri).StatusCode
            Write-Verbose "Refresh token still unexpired, doing nothing"
            return $goog_current_access_token
        }
        else {
            $result = (Invoke-WebRequest -Method Get -Headers $headers -Uri $goog_login_test_uri).StatusCode
            Write-Output "Refresh token has already expired. Tried to get calendars, got http/$result"
        }
    }
    catch {
        Write-Output "Google token was expired, attempting to refresh."
        $token = Invoke-RestMethod -Uri $goog_oauth_uri -Method Post -Body $refreshTokenParams
        Set-AutomationVariable -Name goog_current_access_token -Value $token.access_token
        $expires_datetime = (Get-Date).AddSeconds($($token.expires_in))
        Set-AutomationVariable -Name goog_current_access_token_expiry -Value (Get-Date $expires_datetime -Format "yyyy-MM-dd HH:mm:ss")
        return $($token.access_token)
    }
}
function Get-RotaCurrentGoogleCalendarForDay {
    #todo: this should be filtered on the google side rather than return and filter.
    param (
        $goog_current_access_token = ( Get-AutomationVariable -Name goog_current_access_token ),
        $goog_current_access_token_expiry = ( Get-AutomationVariable -Name goog_current_access_token_expiry ),
        $goog_noah_calendar_id = ( Get-AutomationVariable -Name goog_noah_calendar_id ),
        [ValidateNotNull()]$goog_query_date,
        $headers = @{
            Authorization = "Bearer $goog_current_access_token"
        }
    )

    if ((Get-Date($goog_current_access_token_expiry)) -gt (Get-Date)) {
        Write-Verbose "token has expired, renewing"
        $goog_current_access_token = Update-RotaGoogleAuth
    }

    # get the calendar entry for $goog_query_date
    $calendar_uri = "https://www.googleapis.com/calendar/v3/calendars/$goog_noah_calendar_id/events"
    $obj = Invoke-RestMethod -Method Get -Uri $calendar_uri -Headers $headers
    $goog_query_date = Get-Date($goog_query_date)
    $goog_query_date_end = (Get-Date($goog_query_date)).AddHours(24)
    Write-Verbose "Filtering entries to between $goog_query_date and $goog_query_date_end"
    $return = $obj.items | Where-Object { $_.start.dateTime -ge $goog_query_date -and $_.end.dateTime -le $goog_query_date_end }

    if ($null -ne $return) {
        return $return
    }
    else {
        return "nothing_found"
    }
}
function Remove-RotaCurrentGoogleCalendarForDay {
    param (
        $goog_current_access_token = ( Get-AutomationVariable -Name goog_current_access_token ),
        $goog_current_access_token_expiry = ( Get-AutomationVariable -Name goog_current_access_token_expiry ),
        $goog_noah_calendar_id = ( Get-AutomationVariable -Name goog_noah_calendar_id ),
        [ValidateNotNull()]$goog_query_date,
        $headers = @{
            Authorization = "Bearer $goog_current_access_token"
        },
        $just_remove_them = $false
    )

    if ((Get-Date($goog_current_access_token_expiry)) -gt (Get-Date)) {
        Write-Verbose "token has expired, renewing"
        $goog_current_access_token = Update-RotaGoogleAuth
    }

    # get the calendar entry for $goog_query_date
    $calendar_uri = "https://www.googleapis.com/calendar/v3/calendars/$goog_noah_calendar_id/events"
    $goog_query_date = Get-Date($goog_query_date)
    $goog_query_date_end = (Get-Date($goog_query_date)).AddHours(24)
    $obj = Invoke-RestMethod -Method Get -Uri $calendar_uri -Headers $headers
    $results = $obj.items | Where-Object { $_.start.dateTime -ge $goog_query_date -and $_.end.dateTime -le $goog_query_date_end }
    foreach ($result in $results) {
        $query_date = $($result.start.dateTime)
        $goog_event_id = $($result.id)
        $calendar_uri = "https://www.googleapis.com/calendar/v3/calendars/$goog_noah_calendar_id/events/$goog_event_id"
        Invoke-RestMethod -Method Delete -Uri $calendar_uri -Headers $headers
    }
}
function Add-RotaGoogleCalendarEntry {
    param (
        $goog_current_access_token = ( Get-AutomationVariable -Name goog_current_access_token ),
        $goog_current_access_token_expiry = ( Get-AutomationVariable -Name goog_current_access_token_expiry ),
        $goog_noah_calendar_id = ( Get-AutomationVariable -Name goog_noah_calendar_id ),
        [ValidateNotNull()]$shift_start,
        [ValidateNotNull()]$shift_end,
        $headers = @{
            Authorization = "Bearer $goog_current_access_token"
        }
    )

    if ((Get-Date($goog_current_access_token_expiry)) -gt (Get-Date)) {
        Write-Verbose "token has expired, renewing"
        $goog_current_access_token = Update-RotaGoogleAuth
    }

    # this block inserts a calendar entry.
    $json_calendar_entry = "{
            `"calendarId`": `"$goog_noah_calendar_id`",
            `"description`": `"Tee hee hee, get to work.`",
            `"end`": {
                `"dateTime`": `"$shift_end`",
                `"timeZone`": `"Europe/London`"
            },
            `"summary`": `"LGV Driving`",
            `"start`": {
                `"dateTime`": `"$shift_start`",
                `"timeZone`": `"Europe/London`"
            },
            `"location`": `"Ocado Andover, Walworth Business Park, 89 Flinders Cl, Andover SP10 5AF, UK`",
            `"transparency`": `"transparent`"
        }"
    $new_calendar_insert_uri = "https://www.googleapis.com/calendar/v3/calendars/$goog_noah_calendar_id/events"
    $newEntry = Invoke-RestMethod -Method Post -Uri $new_calendar_insert_uri -Headers $headers -Body $json_calendar_entry
    return $newEntry.status
}
function Invoke-RotaCleanup {
    param (
        $storage_accountKey = ( Get-AutomationVariable -Name "storage_accountKey" ),
        $storage_accountName = ( Get-AutomationVariable -Name "storage_accountName" ),
        $storage_fileshareName = ( Get-AutomationVariable -Name "storage_fileshareName" ),
        $storage_blobContainerName = ( Get-AutomationVariable -Name "storage_blobContainerName" ),
        $storage_accountContext = ( New-AzStorageContext -StorageAccountName $storage_accountName -StorageAccountKey $storage_accountKey ),
        [bool]$pretend_to_do_the_needful = $false
    )
    try {
        if ($pretend_to_do_the_needful -eq $false) {
            Write-Verbose "LIVE mode, below are the files for deletion:"
            Get-AzStorageBlob -Container $storage_blobContainerName -Context $storage_accountContext | Remove-AzStorageBlob
            Get-AzStorageFile -ShareName $storage_fileshareName -context $storage_accountContext | Remove-AzStorageFile
        }
        else {
            Write-Verbose "PRETEND mode, below are the files for deletion:"
            (Get-AzStorageBlob -Container $storage_blobContainerName -Context $storage_accountContext).Name
            (Get-AzStorageFile -ShareName $storage_fileshareName -context $storage_accountContext).Name
        }
    }
    catch {
        Write-Error "Failed to tidy up"
        return $false
    }
}
