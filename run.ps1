$null = Disable-AzContextAutosave -Scope Process
try {
    $AzureConnection = (Connect-AzAccount -Identity).context
}
catch {
    Write-Output "There is no system-assigned user identity. Aborting."
    exit
}
$AzureContext = Set-AzContext -SubscriptionName $AzureConnection.Subscription -DefaultProfile $AzureConnection
Write-Output "Using system-assigned managed identity"
# Above is authentication... that works... don't touch it.

Write-Output "Step1: gather ye' pearls (files to process, now moved into blob."
$jest = Get-RotaScreenshotsForProcessing
Write-Output "Step1: COMPLETED, succuessful or not, I'm just a Write-Host"

Write-Output "Step5: refresh google creds"
$nest = Update-RotaGoogleAuth
Write-Output "Step5: COMPLETED, succuessful or not, I'm just a Write-Host"

foreach ($screenshot in $jest) {
    Write-Output "Step2: Submitting a file (currently hardcoded)"
    $zest = Submit-RotaScreenshotForProcessing $screenshot
    Write-Output "Step2: COMPLETED, succuessful or not, I'm just a Write-Host"

    Write-Output "Step3: wait for azure to confirm DI has done it's jazz all over my file."
    $fest = Get-ProcessedRotaScreenshot $($zest.value)
    Write-Output "Step3: COMPLETED, succuessful or not, I'm just a Write-Host"

    #todo, here we need to crunch output into a google cal.

    Write-Output "Step4: Crunch up the file and hopefully get a nice table."
    $shifts = Get-RotaListOfShifts -di_processed_json $fest
    # $rest | % { New-Object PSObject -Property $_ } | ft -autosize
    Write-Output "Step4: COMPLETED, succuessful or not, I'm just a Write-Host"

    foreach ($shift in $shifts) {
        Write-Verbose "-----"
        if ($($shift.shift_working) -eq $False) {
            Write-Verbose "SHIFT $(Get-Date($shift.date) -Format "yyyy-MM-dd") marked as non working."
        }
        else {
            Write-Verbose "SHIFT $(Get-Date($shift.date) -Format "yyyy-MM-dd") marked as working."
            $start = $(Get-Date($shift.shift_start) -Format "yyyy-MM-ddTHH:mm:ss")
            $end = $(Get-Date($shift.shift_end) -Format "yyyy-MM-ddTHH:mm:ss")
            Add-RotaGoogleCalendarEntry -shift_start $start -shift_end $end
            #todo: need to check and delete previous calendar entries.
        }
    }

}

# Write-Output "Step7: "
# $breast = Get-RotaCurrentGoogleCalendarForDay -goog_query_date "2024-07-22"
# $breast
# Write-Output "Step7: COMPLETED, succuessful or not, Im just a Write-Host"
# Write-Output "End of tests."