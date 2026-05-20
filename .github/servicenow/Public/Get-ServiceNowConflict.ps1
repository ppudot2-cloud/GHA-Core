<#
.SYNOPSIS
    Checks the active ServiceNow Change Request for scheduling conflicts (blackout windows,
    maintenance windows, CI already scheduled) and emits the conflict count as a pipeline variable.

.DESCRIPTION
    Queries the ServiceNow conflict detection API for the active change request and categorises
    any conflicts found into three types:
        - blackout                  — The change falls inside a blackout window.
        - not_in_maintenance_window — The change is outside an allowed maintenance window.
        - ci_already_scheduled      — Another change targeting the same CI is already scheduled.

    The total conflict count is emitted as Azure DevOps pipeline variable
    SNOW_CHANGE_REQUEST_CONFLICT_COUNT so downstream steps can gate on it.

    This function uses two separate try/catch blocks so that a failure to retrieve the
    response does not suppress conflict counting from a partial result, and vice versa.

    NOTE: The conflict iteration uses $response.result.conflicts, but the ServiceNow
    conflict API returns conflicts under $response.result.result (a nested result object).
    This means the foreach loop never executes and all counters remain 0 regardless of
    the actual conflicts returned. The path should be verified against the API response shape.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Int32
    The total number of conflicts found (blackout + maintenance window + CI conflicts).

    Azure DevOps pipeline variables emitted (both isOutput=true and plain):
        SNOW_CHANGE_REQUEST_CONFLICT_COUNT — Integer count of all detected conflicts.

.EXAMPLE
    Get-ServiceNowConflict

    Returns 0 if no conflicts exist, or an integer > 0 indicating the number of conflicts.

.EXAMPLE
    $conflictCount = Get-ServiceNowConflict
    if ($conflictCount -gt 0) {
        throw "Change request has $conflictCount scheduling conflict(s). Resolve before deploying."
    }

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Detect ServiceNow change scheduling conflicts before deployment proceeds
    Dependencies: Invoke-ServiceNowRestApi, Write-ConsoleOutput,
                  $global:change_record (sys_id, number), $global:config (base_uri)

    Known issues:
        - $response.result.conflicts is an incorrect property path for the conflict API.
          The actual conflicts array may be at $response.result.result or directly under
          $response.result depending on the ServiceNow instance version.
        - Write-ConsoleOutput string format calls use -f syntax but pass the format string
          as the -String parameter rather than using PowerShell's -f operator directly,
          which means the format placeholders ({0}, {1}) are not substituted.
#>

function Get-ServiceNowConflict {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    begin {
        $ErrorActionPreference = "Continue"

        $method = "Get"
        # ServiceNow conflict detection API endpoint
        $uri    = "/api/sn_chg_rest/change/$($change_record.sys_id)/conflict"

        # Conflict type counters
        $conflictsExist            = $false
        $blackoutWindowCount       = 0
        $maintenanceWindowCount    = 0
        $ciAlreadyScheduledCount   = 0
    }

    process {
        # -------------------------------------------------------
        # Block 1: Retrieve the conflict response from ServiceNow
        # -------------------------------------------------------
        try {
            Write-ConsoleOutput "Attempting to get the conflict status for change number $($change_record.number) with sys id $($change_record.sys_id)."

            # Limit to 2 retries — conflict checks are time-sensitive in pipeline gating
            $response = Invoke-ServiceNowRestApi -RequestMethod $method -Uri $uri -MaximumRetries 2
            $results  = $response.result
        }
        catch {
            Write-Error "An unhandled exception occurred while processing the ServiceNow response payload. The change request may not be able to proceed with its current schedule."
        }
        finally {
            Write-ConsoleOutput "The ServiceNow Change Request URL is: $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($change_record.sys_id)"
        }

        # -------------------------------------------------------
        # Block 2: Parse and categorise any conflicts found
        # -------------------------------------------------------
        try {
            # Log the full response for diagnostics
            Write-ConsoleOutput -Object $results -ParsedGroupName "ServiceNow response payload for change request conflicts: $($results.number)" -ObjectOutput

            if ($results.record_count -eq 0) {
                Write-ConsoleOutput "Conflicting record count shows $($results.record_count) entries. The change can proceed with its current schedule."
            }

            if ($results.record_count -gt 0) {
                # NOTE: $response.result.conflicts may be an incorrect path — see Known Issues
                foreach ($conflict in $response.result.conflicts) {
                    Write-ConsoleOutput -Object $conflict -ParsedGroupName "ServiceNow change request conflict: $($conflict.type.display_value)" -ObjectOutput

                    # Categorise each conflict by its type value
                    if ($conflict.type.value -eq 'blackout') {
                        $blackoutWindowCount++
                    }
                    elseif ($conflict.type.value -eq 'not_in_maintenance_window') {
                        $maintenanceWindowCount++
                    }
                    elseif ($conflict.type.value -eq 'ci_already_scheduled') {
                        $ciAlreadyScheduledCount++
                    }
                }
            }
        }
        catch {
            Write-Error "An unhandled exception occurred while processing the ServiceNow response payload. The change request may not be able to proceed with its current schedule."
        }
        finally {
            # Sum all conflict types and emit as pipeline variable
            $conflictCount = $blackoutWindowCount + $maintenanceWindowCount + $ciAlreadyScheduledCount

            if ($conflictCount -gt 0) {
                $conflictsExist = $true
            }

            if ($conflictsExist) {
                Write-ConsoleOutput "Change request $($change_record.number) has $($conflictCount) conflict(s)." -Type group
                Write-ConsoleOutput "Blackout conflicts: $($blackoutWindowCount)" -Type debug
                Write-ConsoleOutput "Maintenance Window conflicts: $($maintenanceWindowCount)" -Type debug
                Write-ConsoleOutput "CI Already Scheduled conflicts: $($ciAlreadyScheduledCount)" -Type debug
                Write-ConsoleOutput -EndGroup

                # Emit conflict count as both isOutput=true (cross-job) and plain (same-job)
                Write-Output "##vso[task.setVariable variable=SNOW_CHANGE_REQUEST_CONFLICT_COUNT;isOutput=true]$conflictCount"
                Write-Output "##vso[task.setVariable variable=SNOW_CHANGE_REQUEST_CONFLICT_COUNT]$conflictCount"
            }
        }
    }

    end {
        # Return the total record count from ServiceNow for use by callers
        return $results.record_count
    }
}
