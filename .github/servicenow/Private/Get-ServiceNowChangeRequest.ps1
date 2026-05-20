<#
.SYNOPSIS
    Retrieves a ServiceNow Change Request record by its change ticket number.

.DESCRIPTION
    Queries the ServiceNow change REST API for a specific change request using the module-scoped
    $change_record.number as the lookup key. Returns the full change record object from ServiceNow.

    End-to-end behaviour:
        1. begin block — Sets the HTTP method and constructs the relative URI using the
           sn_chg_rest API endpoint with a sysparm_query filter on the change number.
        2. process block — Builds Basic authentication from $env:ServiceNowUsername /
           $env:ServiceNowPassword, assembles the request parameters, and calls
           Invoke-RestMethod directly. The response .result property is extracted and returned.
        3. finally block — Logs the ServiceNow portal URL for the active change record.
        4. end block — Returns the result object.

    NOTE: This function currently has a known defect — $ChangeTicketNumber is not declared
    as a parameter and $FullUri is never constructed, causing runtime errors. Callers should
    use the $change_record global (populated by New-ServiceNowChangeRequest) for the lookup key
    and pass it via a parameter in a future fix.

.PARAMETER MaximumRetryCount
    Maximum number of retry attempts if the API call fails. Default is 5.

.PARAMETER RetryDelayMilliseconds
    Delay in milliseconds between retry attempts. Default is 15000 (15 seconds).

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The .result payload from ServiceNow containing the full change request record.

.EXAMPLE
    Get-ServiceNowChangeRequest

    Retrieves the change request identified by $change_record.number.

.EXAMPLE
    $cr = Get-ServiceNowChangeRequest -MaximumRetryCount 3 -RetryDelayMilliseconds 5000
    $cr.state

    Fetches the change record with custom retry settings and reads the state field.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Look up an existing ServiceNow Change Request by number
    Dependencies: $global:change_record, $global:config, Write-ConsoleOutput,
                  $env:ServiceNowUsername, $env:ServiceNowPassword

    Known issues:
        - $ChangeTicketNumber is referenced in the URI but never declared as a parameter.
          It must be added as a [Parameter(Mandatory=$true)] or replaced with $change_record.number.
        - $FullUri is used in $Parameters.Uri but is never assigned, causing a null-URI error.
          The URI construction from $uri must be completed using [uri]($config.base_uri + $uri).
#>

function Get-ServiceNowChangeRequest {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param(
        [Parameter(Mandatory = $false)]
        [int] $MaximumRetryCount = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelayMilliseconds = 15000
    )

    begin {
        try {
            $RequestMethod = "Get"

            # TODO: $ChangeTicketNumber must be declared as a parameter or replaced with $change_record.number
            # TODO: $FullUri must be constructed — e.g. [uri]($config.base_uri.TrimEnd('/') + $uri)
            $uri = "/api/sn_chg_rest/change?sysparm_query=number=$($change_record.number)"
        }
        catch {
            # Swallowed — any begin-block error will surface when $uri/$FullUri are used
        }
        finally {
        }
    }

    process {
        try {
            # Build Basic auth header from environment-variable credentials
            $Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $env:ServiceNowUsername, $env:ServiceNowPassword)))

            $Parameters = @{
                "Method"                  = $RequestMethod
                "Uri"                     = $FullUri.AbsoluteUri   # NOTE: $FullUri not yet constructed — see Known Issues
                "StatusCodeVariable"      = "HttpStatusCode"
                "ResponseHeadersVariable" = "ResponseHeaders"
                "Headers"                 = @{
                    "Authorization" = "Basic {0}" -f $Auth
                    "Accept"        = "application/json"
                    "Content-Type"  = "application/json; charset=UTF-8"
                }
            }

            # Log the change request group header
            Write-Host "##[group]Change Request '$($change_record.number)' Details"
            $response = Invoke-RestMethod @Parameters
            $results  = $response.result

            Write-ConsoleOutput "Approval status: $($approvalStatus)" -Type section
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
        try {
            return $results
        }
        catch {
        }
        finally {
        }
    }
}
