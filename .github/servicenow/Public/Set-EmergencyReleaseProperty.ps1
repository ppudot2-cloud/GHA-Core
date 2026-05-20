<#
.SYNOPSIS
    Sets the Emergency Release build property on the current Azure DevOps pipeline run.

.DESCRIPTION
    PATCHes the build properties of the current pipeline run to mark it as an Emergency
    Release. Two properties are set simultaneously:
        /EmergencyReleaseEUS  — Emergency Release flag for the EUS region.
        /EmergencyReleaseSCUS — Emergency Release flag for the SCUS region.

    Both properties are set to the same $PropertyState value ('Pending' or 'Complete'),
    allowing downstream pipeline logic and the Get-EmergencyReleaseProperty function to
    determine whether an emergency release workflow is in progress or has completed.

    The function uses a do/while retry loop for resilience against transient network errors.
    On HTTP 429 (rate limited), it reads the Retry-After header to determine the wait
    duration before retrying.

    NOTE: The 429 rate-limit handling shares the same bug as Get-EmergencyReleaseProperty —
    $retrySleep is only set by the HttpRequestException catch block, but 429 responses do not
    throw exceptions via Invoke-RestMethod. The retry-delay adjustment for 429 therefore
    never executes.

.PARAMETER PropertyState
    The state to assign to both emergency release build properties.
    Valid values:
        'Pending'  — Emergency release is in progress.
        'Complete' — Emergency release has finished.

.PARAMETER MaximumRetries
    Maximum number of retry attempts. Defaults to 5.

.PARAMETER RetryDelay
    Milliseconds to wait between retry attempts. Defaults to 3000 (3 seconds).

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The raw response from Invoke-RestMethod containing the updated build properties.

.EXAMPLE
    Set-EmergencyReleaseProperty -PropertyState 'Pending'

    Marks the current build as an in-progress emergency release for both EUS and SCUS regions.

.EXAMPLE
    Set-EmergencyReleaseProperty -PropertyState 'Complete' -MaximumRetries 3

    Marks the emergency release as complete with a reduced retry budget.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Tag an Azure DevOps pipeline run as an emergency release (Pending or Complete)
    Dependencies: $env:SYSTEM_ACCESSTOKEN, $env:SYSTEM_TEAMPROJECTID, $env:BUILD_BUILDID

    Known issues:
        - 429 rate-limit retry logic never executes — see Description.
        - Body serialisation uses ConvertTo-Json -InputObject which may not produce the
          correct JSON-Patch array format in all PowerShell versions. Verify against ADO API.
#>

function Set-EmergencyReleaseProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Pending', 'Complete')]
        [string] $PropertyState,

        [Parameter(Mandatory = $false)]
        [int] $MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelay = 3000
    )

    begin {
        $restAttempt   = 1
        $retrySleep    = $false
        $ApiVersion    = "7.1"
        $RequestMethod = "Patch"

        # Build the full ADO API URI for build properties
        $BaseUrl  = "https://dev.azure.com/walmart/{0}" -f $env:SYSTEM_TEAMPROJECTID
        [uri]$FullUri = $BaseUrl + "/_apis/build/builds/{0}/properties" -f $env:BUILD_BUILDID

        $parameters = @{
            "Method"                  = $RequestMethod
            "Uri"                     = $FullUri
            "StatusCodeVariable"      = "StatusCode"
            "ResponseHeadersVariable" = "ResponseHeaders"
            "Headers"                 = @{
                "Authorization" = "Bearer {0}" -f $env:SYSTEM_ACCESSTOKEN
                "Accept"        = "application/json;api-version={0}" -f $ApiVersion
                "Content-Type"  = "application/json-patch+json;charset=utf-8"
                "Cache-Control" = "no-cache"
            }
            # JSON-Patch array to set both regional emergency release flags simultaneously
            "Body" = @(
                @{ "op" = "add"; "path" = "/EmergencyReleaseEUS";  "value" = $PropertyState },
                @{ "op" = "add"; "path" = "/EmergencyReleaseSCUS"; "value" = $PropertyState }
            )
        }

        # Serialise the body array to JSON-Patch format before the request loop
        $parameters.Body = $parameters.Body | ConvertTo-Json -InputObject $parameters.Body
    }

    process {
        do {
            try {
                $response = Invoke-RestMethod @parameters
                return $response
            }
            catch [System.Net.Http.HttpRequestException] {
                Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
                Write-Error $PSItem.Exception        -ErrorAction Continue
                Write-Error $PSItem.ErrorDetails.Message -Message "REST API call failed attempt $($restAttempt) of $($MaximumRetries)." -ErrorAction Continue
                $retrySleep = $true
            }
            catch {
                Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
                Write-Error $PSItem.Exception        -ErrorAction Continue
                throw "An unhandled exception was caught."
            }
            finally {
                if ($retrySleep) {
                    $restAttempt++
                    # NOTE: $StatusCode -eq 429 check never triggers — see Known Issues
                    if ($StatusCode -eq 429) {
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
    }
}
