<#
.SYNOPSIS
    Validates that a ServiceNow Change Request is an emergency change in the Implement state,
    then returns its record.

.DESCRIPTION
    Retrieves the specified change request from the ServiceNow emergency change REST endpoint
    and performs two validation checks:
        1. The change type must be 'emergency'.
        2. The change state must be '-1' (Implement).

    If either check fails, the function throws a terminating error to halt the pipeline.
    If both pass, the function returns the full change record for use by downstream steps.

    This function is typically used at the start of an emergency release pipeline to confirm
    that the referenced change ticket is valid and in the correct state before proceeding
    with deployment.

.PARAMETER EmergencyChangeId
    The change request number to validate (e.g. CHG0012345). This is looked up via the
    ServiceNow emergency change REST API endpoint.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The .result payload from ServiceNow containing the validated emergency change record.
    Includes fields such as: type, state, number, sys_id, short_description, etc.

.EXAMPLE
    Get-ServiceNowEmergencyChange -EmergencyChangeId "CHG0012345"

    Validates CHG0012345 is an emergency change in Implement state and returns the record.

.EXAMPLE
    $emergencyChange = Get-ServiceNowEmergencyChange -EmergencyChangeId $env:SNOW_EMERGENCY_CHANGE_ID
    $emergencyChange.sys_id   # Use sys_id for subsequent ServiceNow API calls

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Validate an emergency change request before proceeding with emergency deployment
    Dependencies: Invoke-ServiceNowRestApi, Write-ConsoleOutput,
                  $global:config (base_uri), $global:change_record (sys_id)

    ServiceNow state codes:
        -5 = New     -4 = Assess    -3 = Authorize
        -2 = Scheduled    -1 = Implement    0 = Review
         3 = Closed        4 = Cancelled
#>

function Get-ServiceNowEmergencyChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $EmergencyChangeId
    )

    begin {
        try {
            Write-ConsoleOutput "Attempting to get the change type and current status for change number $($EmergencyChangeId)." -Type debug

            # Build the URI using the ServiceNow emergency change REST endpoint
            $uri = "/api/sn_chg_rest/change/emergency?sysparm_query=number=$($EmergencyChangeId)"
        }
        catch {
            # Errors constructing the URI surface when it is used in the process block
        }
        finally {
        }
    }

    process {
        try {
            # Fetch the emergency change record from ServiceNow
            $response = Invoke-ServiceNowRestApi -RequestMethod Get -Uri $uri
            $results  = $response.result

            # Log the full result object as a collapsible group for diagnostics
            Write-ConsoleOutput $results -ParsedGroupName "Results are: " -ObjectOutput

            # Validate change type — must be 'emergency'
            if ($results.type -ne 'emergency') {
                throw "Change Request $($EmergencyChangeId) is NOT an emergency change."
            }

            # Validate change state — must be -1 (Implement)
            if ($results.state -ne '-1') {
                throw "Change Request $($EmergencyChangeId) is NOT in the 'Implement' phase."
            }

            return $results
        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            Write-Host $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            # Log the ServiceNow portal link for easy navigation
            Write-ConsoleOutput "The ServiceNow Change Request URL is: $($config.base_uri)/api/sn_chg_rest/change/emergency?sysparm_query=number=$($EmergencyChangeId)"
        }
    }

    end {
        try {
        }
        catch {
        }
        finally {
        }
    }
}
