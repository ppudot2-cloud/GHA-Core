<#
.SYNOPSIS
    Requests approval for a ServiceNow Change Request, auto-approves Low risk changes,
    then transitions the change to the Implement state.

.DESCRIPTION
    Drives the approval lifecycle for the active change request through three phases:

        Phase 1 — Submit for Approval.
            PATCHes the change request with approval='Requested' and state='Assess'
            to initiate the formal approval workflow in ServiceNow.

        Phase 2 — Auto-Approve Low Risk Changes.
            When $change_record.risk_level is 'Low' (or the numeric equivalent '4'),
            automatically retrieves the approver sys_id from the sysapproval_approver
            table and PUTs an approval record with state='Approved'. Includes one retry
            if the approver is not found on the first attempt.

        Phase 3 — Wait for Scheduled State.
            Polls the change request state until it reaches -2 (Scheduled), retrying
            up to $ScheduledStateMaximumRetries times with $ScheduledStateRetryDelay
            milliseconds between polls. Throws a warning-level error if the maximum
            retries are reached before the change moves to Scheduled.

        Phase 4 — Move to Implement.
            PATCHes the change request with state='Implement' to signal that deployment
            can proceed.

.PARAMETER ScheduledStateMaximumRetries
    Maximum number of polling attempts while waiting for the change to reach Scheduled
    state. Defaults to 5.

.PARAMETER ScheduledStateRetryDelay
    Milliseconds to wait between Scheduled-state polling attempts. Defaults to 10000 (10s).

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    None. Side effects: multiple PATCH/PUT calls to ServiceNow.

.EXAMPLE
    Request-ServiceNowApproval

    Runs the full approval flow with default retry settings.

.EXAMPLE
    Request-ServiceNowApproval -ScheduledStateMaximumRetries 8 -ScheduledStateRetryDelay 15000

    Waits up to 8 attempts (2 minutes total at 15s each) for the change to reach Scheduled.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Drive the ServiceNow change approval lifecycle from an Azure DevOps pipeline
    Dependencies: Invoke-ServiceNowRestApi, Write-ConsoleOutput,
                  $global:change_record (sys_id, number, risk_level), $global:config (base_uri)

    ServiceNow state numeric codes:
        -5 = New, -4 = Assess, -3 = Authorize, -2 = Scheduled
        -1 = Implement, 0 = Review, 3 = Closed, 4 = Cancelled

    ServiceNow approval numeric codes:
        0 = Requested, 1 = Approved, 2 = Rejected

    Note: The Scheduled-state check uses $approvalResults.state rather than a fresh
    change_request GET, which may not reflect the actual CR state if the variable was
    not updated in the Low-risk auto-approval path.
#>

function Request-ServiceNowApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int] $ScheduledStateMaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $ScheduledStateRetryDelay = 10000
    )

    begin {
        $ErrorActionPreference = "Stop"
    }

    process {
        try {
            Write-ConsoleOutput "Request Approval for Change: $($change_record.number)" -Type group

            $uri = "/api/now/table/change_request/$($change_record.sys_id)"

            # -------------------------------------------------------
            # Phase 1: Submit for approval — move to Assess state
            # -------------------------------------------------------
            $body = @{
                'approval' = 'Requested'
                'state'    = 'Assess'
            }

            $json     = $body | ConvertTo-Json -Compress -Depth 100
            $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Patch -Body $json

            # -------------------------------------------------------
            # Phase 2: Auto-approve Low risk changes (risk_level = 'Low' or '4')
            # -------------------------------------------------------
            if ($change_record.risk_level -eq 'Low' -or $change_record.risk_level -eq '4') {
                # Retrieve the approver's sys_id from the approval record
                $approverUri = "/api/now/table/sysapproval_approver?sysparm_query=sysapproval=$($change_record.sys_id)&sysparm_limit=1"

                Write-ConsoleOutput "Change request: $($change_record.number) is marked as Low Risk"
                Write-ConsoleOutput "Retrieving Approvers Unique ID for automatic approval"

                $response        = Invoke-ServiceNowRestApi -Uri $approverUri -RequestMethod Get
                $approverResults = $response.result

                if ([string]::IsNullOrWhiteSpace($approverResults.approver.value)) {
                    # Approver not yet available — retry once after a brief implicit delay
                    Write-ConsoleOutput "No approver information returned from ServiceNow on first attempt. Retrying..." -Type warning
                    $response        = Invoke-ServiceNowRestApi -Uri $approverUri -RequestMethod Get
                    $approverResults = $response.result
                    Write-ConsoleOutput "Approver information returned from second try: $($approverResults)"
                }

                Write-ConsoleOutput "Approver id is: $($approverResults.approver.value)"

                # PUT the approval record to set state='Approved'
                $approvalUri = "/api/now/table/sysapproval_approver/$($approverResults.sys_id)"

                $body = @{
                    'state'    = 'Approved'
                    'approver' = $approverResults.approver.value
                }

                $json            = $body | ConvertTo-Json -Compress -Depth 100
                $response        = Invoke-ServiceNowRestApi -Uri $approvalUri -RequestMethod Put -Body $json
                $approvalResults = $response.result

                if ($approvalResults.approval.value -eq 'approved') {
                    Write-ConsoleOutput "Change request $($change_record.number) has been approved successfully." -Type section
                }
            }

            # -------------------------------------------------------
            # Phase 3: Poll until the change reaches Scheduled state (-2)
            # -------------------------------------------------------
            Write-ConsoleOutput "Change request move to Scheduled state" -Type group

            if ($approvalResults.state -ne -2) {
                Write-ConsoleOutput "Waiting $($ScheduledStateRetryDelay / 1000) seconds before checking if change request $($change_record.number) has moved to the Scheduled state."

                $i = 0
                while ($i -lt $ScheduledStateMaximumRetries) {
                    Write-ConsoleOutput "Change request $($change_record.number) has not yet moved to Scheduled. Will retry in $($ScheduledStateRetryDelay / 1000) seconds."
                    Start-Sleep -Milliseconds $ScheduledStateRetryDelay

                    # Re-fetch the change request to check its current state
                    $response        = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Get
                    $approvalResults = $response.result

                    if ($approvalResults.state -eq -2) {
                        Write-ConsoleOutput "Change request $($change_record.number) has been moved to Scheduled."
                        break
                    }
                    $i++
                }

                # If max retries exhausted without reaching Scheduled, fail the pipeline step
                if ($i -ge $ScheduledStateMaximumRetries) {
                    $message = "Waiting for change request $($change_record.number) to be moved to Scheduled has reached the max amount of retry attempts. Re-run the pipeline job to try again."
                    Write-ConsoleOutput $message -Type warning
                    throw $message
                }
            }

            # -------------------------------------------------------
            # Phase 4: Move the change to Implement state
            # -------------------------------------------------------
            Write-ConsoleOutput "================================================================"
            Write-ConsoleOutput "Attempting to move change request $($change_record.number) to Implement"
            Write-ConsoleOutput "================================================================"

            $body     = @{ 'state' = 'Implement' }
            $json     = $body | ConvertTo-Json -Compress -Depth 100
            $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Patch -Body $json
            $results  = $response.result

            # Display final state of the change record
            $output = [ordered]@{}
            foreach ($property in $results.psobject.properties.name) {
                if (\![string]::IsNullOrWhiteSpace($results.$property)) {
                    $output[$property] = $results.$property
                }
            }

            Write-ConsoleOutput "===== Request Change Approval Results Begin ====="
            $output | Format-Table
            Write-ConsoleOutput "===== Request Change Approval Results End ====="
        }
        catch {
            Write-Output $PSItem.ScriptStackTrace
            Write-Output $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            Write-ConsoleOutput "The ServiceNow Change Request URL is: $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($change_record.sys_id)"
        }
    }

    end {
    }
}
