<#
.SYNOPSIS
    Retrieves the custom build properties for the current Azure DevOps pipeline run.

.DESCRIPTION
    Calls the Azure DevOps Build Properties REST API to fetch all custom properties
    associated with the current pipeline build. These properties include metadata set by
    Set-PipelineProperties (e.g. changeTicketNumber, deploymentApprover, gitCommitId) and
    emergency release flags set by Set-EmergencyReleaseProperty.

    The function retries on transient HttpRequestException failures. On HTTP 429 (rate
    limited), it reads the Retry-After response header to determine the wait duration.

    NOTE: The 429 rate-limit handling never executes because $retrySleep is only set to
    $true in the HttpRequestException catch block, but the finally block checks $retrySleep
    before $StatusCode — and $retrySleep will always be false when $StatusCode is 429 (since
    a 429 would have been returned as a successful Invoke-RestMethod response, not an exception).
    A robust fix would use Invoke-WebRequest with SkipHttpErrorCheck and check status codes
    directly.

.PARAMETER MaximumRetries
    Maximum number of retry attempts for failed REST API calls. Defaults to 5.

.PARAMETER RetryDelay
    Delay in milliseconds between retry attempts. Defaults to 3000 (3 seconds).

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The build properties response object from the Azure DevOps API. Contains a .value
    property with the custom build properties as key-value pairs.

.EXAMPLE
    Get-EmergencyReleaseProperty

    Returns all custom properties for the current build using default retry settings.

.EXAMPLE
    $props = Get-EmergencyReleaseProperty -MaximumRetries 10 -RetryDelay 5000
    $props.value

    Fetches properties with extended retry configuration and accesses the values directly.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Retrieve Azure DevOps build properties for emergency release and change ticket inspection
    Dependencies: $env:SYSTEM_ACCESSTOKEN, $env:SYSTEM_TEAMPROJECTID, $env:BUILD_BUILDID

    Known issues:
        - 429 rate-limit retry logic never executes — see Description for explanation.
        - After MaximumRetries exhaustion the function throws, but the error message says
          "REST API call has failed" without indicating which endpoint failed.
#>

function Get-EmergencyReleaseProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int] $MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelay = 3000
    )

    begin {
        $restAttempt = 1
        $retrySleep  = $false
        $ApiVersion  = "7.1"
        $RequestMethod = "Get"

        # Build the full ADO API URI for build properties
        $BaseUrl = "https://dev.azure.com/walmart/{0}" -f $env:SYSTEM_TEAMPROJECTID
        [uri]$FullUri = $BaseUrl + "/_apis/build/builds/{0}/properties" -f $env:BUILD_BUILDID

        $parameters = @{
            "Method"                  = $RequestMethod
            "Uri"                     = $FullUri
            "StatusCodeVariable"      = "StatusCode"
            "ResponseHeadersVariable" = "ResponseHeaders"
            "Headers"                 = @{
                "Authorization"   = "Bearer {0}" -f $env:SYSTEM_ACCESSTOKEN
                "Accept-Language" = "en-US"
                "Content-Type"    = "application/json-patch+json;charset=utf-8;api-version={0}" -f $ApiVersion
                "Cache-Control"   = "no-cache"
            }
        }
    }

    process {
        do {
            Write-ConsoleOutput "REST API attempt: $($restAttempt)"

            try {
                $response = Invoke-RestMethod @parameters
                return $response
            }
            catch [System.Net.Http.HttpRequestException] {
                # Transient network error — schedule a retry
                Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
                Write-Error $PSItem.Exception        -ErrorAction Continue
                Write-Error $PSItem.ErrorDetails.Message -Message "REST API call failed attempt $($restAttempt) of $($MaximumRetries)." -ErrorAction Continue
                $retrySleep = $true
            }
            catch {
                # Non-retryable error — fail immediately
                Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
                Write-Error $PSItem.Exception        -ErrorAction Continue
                throw "An unhandled exception was caught."
            }
            finally {
                if ($retrySleep) {
                    $restAttempt++
                    # NOTE: 429 handling never triggers — $retrySleep is only set by HttpRequestException,
                    # not by HTTP 429 responses (which do not throw via Invoke-RestMethod)
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
