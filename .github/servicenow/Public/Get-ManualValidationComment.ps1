<#
.SYNOPSIS
    Retrieves the resume comment typed by a user on an ADO ManualValidation task.

.DESCRIPTION
    When a ManualValidation@1 task runs in an agentless job (pool: server), ADO
    internally creates a distributed task plan approval scoped to the current
    pipeline run. When the user clicks Resume they can optionally type a comment
    in the approval dialog — this function retrieves that comment via the ADO
    Distributed Task Plans REST API.

    The function uses SYSTEM_PLANID to scope the query to the current pipeline
    run, filters the returned approval records for a completed (status 4) approval,
    and returns the comment text the user submitted.

    Typical usage: call this function in the first step of the agent job that
    immediately follows the agentless ManualValidation job to read what the user
    typed (e.g. an existing ServiceNow Change Ticket Number) before deciding
    whether to create a new Change Request or reuse an existing one.

    If no completed approval is found the function returns an empty string and
    emits a warning rather than throwing, so the pipeline can default safely to
    the no-input path.

.PARAMETER MaximumRetries
    Maximum number of retry attempts for failed REST API calls. Defaults to 5.

.PARAMETER RetryDelay
    Delay in milliseconds between retry attempts. Defaults to 3000 (3 seconds).

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.String
    The trimmed comment text typed by the user when resuming the ManualValidation
    task, or an empty string if the user left the comment blank or no completed
    approval record was found.

.EXAMPLE
    $ticket = Get-ManualValidationComment

    Returns "CHG0040007" if the user typed that when resuming ManualValidation,
    or an empty string if the user clicked Resume without entering a comment.

.EXAMPLE
    $ticket = Get-ManualValidationComment -MaximumRetries 3 -RetryDelay 5000

    Retrieves the resume comment with custom retry settings.

.EXAMPLE
    $ticket = Get-ManualValidationComment
    if ([string]::IsNullOrEmpty($ticket)) {
        New-ServiceNowChangeRequest
    } else {
        Write-ConsoleOutput "Using existing Change Request: $ticket"
    }

    Typical branching pattern — create a new CR or reuse the one the user provided.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : April 2026
    Version     : 1.0
    Purpose     : Read the user's ManualValidation resume comment via the ADO REST API
    Dependencies: Write-ConsoleOutput, $env:SYSTEM_ACCESSTOKEN,
                  $env:SYSTEM_TEAMPROJECTID, $env:SYSTEM_PLANID

    ADO distributed task approval status codes:
        1 = Pending
        2 = Rejected
        4 = Approved / Resumed

    The comment field name returned by the API varies across ADO versions:
        Newer versions : 'comments' (plural)
        Older versions : 'comment'  (singular)
    Both are handled via the null-coalescing operator — no code change required.
#>

function Get-ManualValidationComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int] $MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelay = 3000
    )

    begin {
        try {
            $restAttempt   = 1
            $retrySleep    = $false
            $ApiVersion    = "7.1"
            $RequestMethod = "Get"

            # Build the full ADO Distributed Task Plans URI for the current pipeline run.
            # SYSTEM_PLANID uniquely scopes the approvals query to this run only.
            $BaseUrl  = "https://dev.azure.com/walmart/{0}" -f $env:SYSTEM_TEAMPROJECTID
            [uri]$FullUri = $BaseUrl + "/_apis/distributedtask/hubs/build/plans/{0}/approvals" -f $env:SYSTEM_PLANID

            $parameters = @{
                "Method"                  = $RequestMethod
                "Uri"                     = $FullUri
                "StatusCodeVariable"      = "StatusCode"
                "ResponseHeadersVariable" = "ResponseHeaders"
                "Headers"                 = @{
                    "Authorization"   = "Bearer {0}" -f $env:SYSTEM_ACCESSTOKEN
                    "Accept-Language" = "en-US"
                    "Content-Type"    = "application/json;charset=utf-8;api-version={0}" -f $ApiVersion
                    "Cache-Control"   = "no-cache"
                }
            }

            Write-ConsoleOutput "Fetching ManualValidation approval — plan: $($env:SYSTEM_PLANID)" -Type debug
        }
        catch {
        }
        finally {
        }
    }

    process {
        do {
            Write-ConsoleOutput "REST API attempt: $($restAttempt)"

            try {
                $response = Invoke-RestMethod @parameters

                # Filter to the most recently completed (Approved/Resumed) approval.
                # Status 4 = Approved/Resumed in the ADO distributed task status enum.
                $approval = $response.value |
                                Where-Object  { $_.status -eq 4 -or $_.status -eq 'approved' } |
                                Sort-Object   { $_.lastModified } -Descending |
                                Select-Object -First 1

                if ($null -eq $approval) {
                    Write-ConsoleOutput "No completed ManualValidation approval found for plan '$($env:SYSTEM_PLANID)'. Defaulting to empty comment." -Type debug
                    Write-ConsoleOutput "Full approvals response:`n$($response | ConvertTo-Json -Depth 5)" -Type debug
                    return ''
                }

                # Try 'comments' (newer ADO) then 'comment' (older ADO) then empty string
                $comment = ($approval.comments ?? $approval.comment ?? '').Trim()

                Write-ConsoleOutput "ManualValidation resume comment received: '$($comment)'"
                return $comment
            }
            catch [System.Net.Http.HttpRequestException] {
                # Transient network error — log all details and schedule a retry
                Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
                Write-Error $PSItem.Exception        -ErrorAction Continue
                Write-Error $PSItem.ErrorDetails.Message -Message "REST API call failed attempt $($restAttempt) of $($MaximumRetries)." -ErrorAction Continue
                $retrySleep = $true
            }
            catch {
                # Non-retryable error — log and fail immediately
                Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
                Write-Error $PSItem.Exception        -ErrorAction Continue
                throw "An unhandled exception was caught."
            }
            finally {
                if ($retrySleep) {
                    $restAttempt++
                    if ($StatusCode -eq 429) {
                        # Back off using the server-specified Retry-After interval
                        $RetryDelay = $ResponseHeaders['Retry-After']
                    }
                    Write-ConsoleOutput "Waiting: $($RetryDelay) milliseconds before attempt $($restAttempt)"
                    Start-Sleep -Milliseconds $RetryDelay
                    $retrySleep = $false
                }
            }

        } while ($restAttempt -lt $MaximumRetries)

        throw "Maximum retries have been reached. REST API call has failed and will not be retried."
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
