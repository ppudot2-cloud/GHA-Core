<#
.SYNOPSIS
    Closes a ServiceNow Change Request by setting its close code, notes, and transitioning
    its state through Review to Closed.

.DESCRIPTION
    Executes a three-step state transition on the active change request:
        1. PATCH close_code + close_notes  — records the deployment outcome.
        2. PATCH state -> Review (or Cancelled=4 if CloseCode was "Cancel") — moves the CR
           out of Implement into the review phase.
        3. PATCH state -> Closed — finalises the change record (skipped for Cancel).

    Each PATCH is made via Invoke-ServiceNowRestApi which handles authentication and retries.
    The function also calls Set-PipelineProperties in the begin block to stamp ADO build
    properties with change ticket metadata before closing.

.PARAMETER CloseCode
    The ServiceNow closure code. Must be one of:
        'Successful'             — Deployment completed without issues.
        'Successful with issues' — Deployment completed but with non-blocking problems.
        'Unsuccessful'           — Deployment failed or was rolled back.

.PARAMETER CloseNotes
    Free-text closure notes added to the change record. Typically includes job status,
    timestamps, and any relevant context about the deployment outcome.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    None. Side effects: three PATCH calls to ServiceNow. Final state is Closed (or Cancelled).

.EXAMPLE
    Close-ServiceNowChangeRequest -CloseCode "Successful" `
        -CloseNotes "Deployment completed successfully. All smoke tests passed."

    Transitions the CR through Review -> Closed with a 'Successful' close code.

.EXAMPLE
    Close-ServiceNowChangeRequest -CloseCode $SNOW_CLOSURE_STATUS `
        -CloseNotes "Deployment - Job Status: $($SNOW_CLOSURE_STATUS)"

    Typical pipeline usage where closure code is determined by the deployment result variable.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Close a ServiceNow Change Request after a pipeline deployment completes
    Dependencies: Set-PipelineProperties, Invoke-ServiceNowRestApi, Write-ConsoleOutput,
                  $global:change_record (sys_id, number, build_uid), $global:config (base_uri)

    Known issues:
        - The "Cancel" branch in $CloseCode checks is dead code — 'Cancel' is not in the
          ValidateSet, so it can never be passed as a valid parameter value.
        - ($body | ConvertTo-Json -Compress -Depth 100).Replace('\n', '\n') is a no-op.
          To preserve literal newlines the replacement should be .Replace('\n', '\\n') or
          similar. Currently has no effect.
#>

function Close-ServiceNowChangeRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Successful", "Successful with issues", "Unsuccessful")]
        [string] $CloseCode,

        [Parameter(Mandatory = $true)]
        [string] $CloseNotes
    )

    begin {
        $ErrorActionPreference = "Stop"
        # Stamp the ADO build with change ticket metadata before closing
        Set-PipelineProperties
    }

    process {
        try {
            Write-ConsoleOutput "Attempting to update change request close code and notes"

            # All three PATCH calls target the same change_request record
            $uri = "/api/now/table/change_request/$($change_record.sys_id)"

            # -------------------------------------------------------
            # Step 1: Set close code and close notes
            # -------------------------------------------------------
            if ($CloseCode -eq "Cancel") {
                # NOTE: Dead code — 'Cancel' is not in the ValidateSet
                $body = @{
                    'close_code'  = "Unsuccessful"
                    'close_notes' = $CloseNotes
                }
            }
            else {
                $body = @{
                    'close_code'  = $CloseCode.ToLower()
                    'close_notes' = $CloseNotes
                }
            }

            # NOTE: .Replace('\n', '\n') is a no-op — does not escape newlines
            $json = ($body | ConvertTo-Json -Compress -Depth 100).Replace('\n', '\n')

            $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Patch -Body $json
            $results  = $response.result

            # Collect non-null result fields for display
            $output = [ordered]@{}
            foreach ($property in $results.psobject.properties.name) {
                if (\![string]::IsNullOrWhiteSpace($results.$property)) {
                    $output[$property] = $results.$property
                }
            }

            Write-ConsoleOutput "===== Close Code Change Record Results Begin ====="
            $output | Format-Table
            Write-ConsoleOutput "===== Close Code Change Record Results End ====="

            Write-ConsoleOutput "Successfully updated change request $($change_record.number) with closure notes." -Type section
            Write-ConsoleOutput "Close code was: $($CloseCode)" -Type section

            # -------------------------------------------------------
            # Step 2: Transition state to Review (or Cancelled)
            # -------------------------------------------------------
            if ($CloseCode -eq "Cancel") {
                # NOTE: Dead code — 'Cancel' is not in ValidateSet
                Write-ConsoleOutput "Attempting to move change request to Cancel and set Actual End date"
                $body = @{
                    'state'       = "4"
                    'cancel_code' = "Unsuccessful"
                    'reason'      = "The pipeline run with id: $($change_record.build_uid) was canceled."
                }
            }
            else {
                Write-ConsoleOutput "Attempting to move change request to Review and set Actual End date"
                $body = @{ 'state' = "Review" }
            }

            $json     = $body | ConvertTo-Json -Compress -Depth 100
            $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Patch -Body $json
            $results  = $response.result

            $output = [ordered]@{}
            foreach ($property in $results.psobject.properties.name) {
                if (\![string]::IsNullOrWhiteSpace($results.$property)) {
                    $output[$property] = $results.$property
                }
            }

            Write-ConsoleOutput "===== State Review Change Record Results Begin ====="
            $output | Format-Table
            Write-ConsoleOutput "===== State Review Change Record Results End ====="

            # -------------------------------------------------------
            # Step 3: Transition state to Closed (skipped for Cancel)
            # -------------------------------------------------------
            if ($CloseCode -ne "Cancel") {
                Write-ConsoleOutput "Moved ServiceNow change request: $($change_record.number) to the 'Review' phase" -Type section
                Write-ConsoleOutput "Now attempting to move change request to the 'Closed' phase."

                $body     = @{ 'state' = 'Closed' }
                $json     = $body | ConvertTo-Json -Compress -Depth 100
                $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Patch -Body $json
                $results  = $response.result

                $output = [ordered]@{}
                foreach ($property in $results.psobject.properties.name) {
                    if (\![string]::IsNullOrWhiteSpace($results.$property)) {
                        $output[$property] = $results.$property
                    }
                }

                Write-ConsoleOutput "===== State Closed Change Record Results Begin ====="
                $output | Format-Table
                Write-ConsoleOutput "===== State Closed Change Record Results End ====="

                Write-ConsoleOutput "Moved ServiceNow change request: $($change_record.number) correctly" -Type section
            }
        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            Write-Host $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            # Always log the ServiceNow portal URL for easy navigation
            Write-ConsoleOutput "The ServiceNow Change Request URL is: $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($change_record.sys_id)"
        }
    }

    end {
    }
}
