<#
.SYNOPSIS
    Creates a new ServiceNow Change Request and publishes its identifiers as Azure DevOps
    pipeline variables.

.DESCRIPTION
    Opens a new ticket in the ServiceNow change_request table, scheduled to cover the
    release window corresponding to the next occurrence of the caller-supplied day of week.

    End-to-end behaviour:

        1. begin block — Calls Resolve-PlannedReleaseWindow with -DesiredDayOfWeek to obtain
           a hashtable with .Start and .End DateTime strings for the deployment window.

        2. process block / try — Builds the ServiceNow REST URI with sysparm_display_value=true
           and sysparm_input_display_value=true (returns and accepts human-readable field values).
           Merges start_date and end_date onto the global $body object, serialises to JSON, and
           POSTs via Invoke-ServiceNowRestApi. Returns the .result payload from ServiceNow
           (the full newly-created change record).

        3. process block / catch — Logs stack trace and exception, then rethrows
           $PSItem.ErrorDetails.Message as a terminating error.

        4. process block / finally — Runs unconditionally. Logs change request details
           (number, URL, sys_id, risk level) in a collapsible group, then emits three
           Azure DevOps pipeline variables both as isOutput=true (cross-job) and plain
           (same-job):
               SNOW_CHANGE_REQUEST_NUMBER
               SNOW_CHANGE_REQUEST_ID
               SNOW_CHANGE_RISK_LEVEL

.PARAMETER DesiredDayOfWeek
    The day of the week on which the change should be scheduled
    (e.g. 'Monday', 'Tuesday', 'Thursday'). Passed through to Resolve-PlannedReleaseWindow
    which maps it to a concrete Start/End window according to the org's CAB calendar.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The .result payload from ServiceNow — the newly created change request record.
    Contains at minimum: sys_id, number, state, risk, and all fields from the $body template.

    Pipeline variables emitted (both isOutput=true and plain):
        SNOW_CHANGE_REQUEST_NUMBER — The change number (e.g. CHG0012345)
        SNOW_CHANGE_REQUEST_ID     — The ServiceNow sys_id GUID
        SNOW_CHANGE_RISK_LEVEL     — The calculated risk level string

.EXAMPLE
    New-ServiceNowChangeRequest -DesiredDayOfWeek 'Tuesday'

    Creates a change request for next Tuesday's release window. After the call, pipeline
    steps can read $(SNOW_CHANGE_REQUEST_NUMBER), $(SNOW_CHANGE_REQUEST_ID), and
    $(SNOW_CHANGE_RISK_LEVEL).

.EXAMPLE
    $cr = New-ServiceNowChangeRequest -DesiredDayOfWeek 'Wednesday'
    $cr.number   # e.g. CHG0012345
    $cr.sys_id   # e.g. a1b2c3d4e5f6...

    Captures the returned change record to read fields directly in addition to pipeline vars.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Create a ServiceNow Change Request from an Azure DevOps pipeline
    Dependencies: Resolve-PlannedReleaseWindow, Invoke-ServiceNowRestApi, Write-ConsoleOutput,
                  $global:body (must be pre-populated before calling this function),
                  $global:config (base_uri for the portal URL log line)

    Note: Pipeline variable emission happens in finally, so variables are set even if the
    POST fails. In that case the values will be empty strings — downstream steps should
    validate SNOW_CHANGE_REQUEST_NUMBER is non-empty before proceeding.
#>
function New-ServiceNowChangeRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DesiredDayOfWeek
    )

    begin {
        # Calculate the deployment window (Start/End) for the target day of week
        $timespan = Resolve-PlannedReleaseWindow -DesiredDayOfWeek $DesiredDayOfWeek
    }

    process {
        try {
            # Use display-value mode so ServiceNow accepts/returns human-readable field values
            $uri = "/api/now/table/change_request?sysparm_display_value=true&sysparm_input_display_value=true"

            # Merge the computed window into the global body template (overwrite any existing dates)
            $body | Add-Member -NotePropertyMembers @{
                "start_date" = $timespan.Start
                "end_date"   = $timespan.End
            } -Force

            $json = $body | ConvertTo-Json -Compress -Depth 100

            Write-ConsoleOutput "Attempting to create the ServiceNow Change ticket"

            # POST the change request payload to ServiceNow
            $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Post -Body $json
            $results  = $response.result

            # Log the full response payload as a collapsible group for debugging
            Write-ConsoleOutput -Object $results -ParsedGroupName "ServiceNow response payload for new change request: $($results.number)" -ObjectOutput

            return $results
        }
        catch {
            Write-Output $PSItem.ScriptStackTrace
            Write-Output $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            # Always log and emit pipeline variables, even on failure (values may be empty)
            Write-ConsoleOutput "ServiceNow change request details: $($results.number)" -Type group
            Write-ConsoleOutput "Request URL : $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($results.sys_id)"
            Write-ConsoleOutput "Request Number : $($results.number)"
            Write-ConsoleOutput "Request Unique Identifier : $($results.sys_id)"
            Write-ConsoleOutput "Request Calculated Risk Level : $($results.risk)"
            Write-ConsoleOutput -EndGroup

            # Emit as isOutput=true (cross-job consumption via dependencies.<job>.outputs['step.VAR'])
            Write-Output "##vso[task.setvariable variable=SNOW_CHANGE_REQUEST_NUMBER;isOutput=true]$($results.number)"
            # Emit as plain variable for same-job consumption via $(SNOW_CHANGE_REQUEST_NUMBER)
            Write-Output "##vso[task.setvariable variable=SNOW_CHANGE_REQUEST_NUMBER]$($results.number)"
            Write-Output "##vso[task.setvariable variable=SNOW_CHANGE_REQUEST_ID;isOutput=true]$($results.sys_id)"
            Write-Output "##vso[task.setvariable variable=SNOW_CHANGE_REQUEST_ID]$($results.sys_id)"
            Write-Output "##vso[task.setvariable variable=SNOW_CHANGE_RISK_LEVEL;isOutput=true]$($results.risk)"
            Write-Output "##vso[task.setvariable variable=SNOW_CHANGE_RISK_LEVEL]$($results.risk)"
        }
    }

    end {
    }
}
