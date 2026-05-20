<#
.SYNOPSIS
    Checks the current Azure DevOps pipeline build for an emergency release tag and emits
    the EMERGENCY_RELEASE_FLAG pipeline variable.

.DESCRIPTION
    Calls the Azure DevOps Build Tags REST API to retrieve all tags on the current pipeline
    build. It scans each tag against a regex pattern that matches variations of
    "Emergency Release" (case-insensitive, either word order). If a matching tag is found,
    the function sets EMERGENCY_RELEASE_FLAG=true; otherwise false.

    This flag is used by downstream pipeline stages to decide whether to invoke the
    emergency change request workflow instead of the standard change management path.

    The function uses a do/while retry loop for resilience against transient failures.
    On HTTP 429 responses, it reads the Retry-After header to adjust the wait interval.

    NOTE: Both Write-ConsoleOutput calls in the tag-iteration loop use -debug as a bare
    switch instead of -Type debug (which is the correct parameter syntax). This causes
    the function to fail with a parameter binding error.

    NOTE: The 429 retry-delay adjustment shares the same never-triggers bug as the other
    ADO property functions — see Get-EmergencyReleaseProperty for the explanation.

.PARAMETER MaximumRetries
    Maximum number of retry attempts. Defaults to 5.

.PARAMETER RetryDelay
    Delay in milliseconds between retry attempts. Defaults to 3000 (3 seconds).

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Boolean
    $true if an emergency release tag was found; $false otherwise.

    Azure DevOps pipeline variables emitted:
        EMERGENCY_RELEASE_FLAG — 'true' or 'false' (both isOutput=true and plain)

.EXAMPLE
    Get-EmergencyReleaseTag

    Returns $true and sets EMERGENCY_RELEASE_FLAG=true if the build has an "Emergency Release" tag.

.EXAMPLE
    $isEmergency = Get-EmergencyReleaseTag
    if ($isEmergency) { Invoke-EmergencyReleaseWorkflow }

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Detect whether a pipeline run is tagged for emergency release
    Dependencies: Write-ConsoleOutput, $env:SYSTEM_ACCESSTOKEN,
                  $env:SYSTEM_TEAMPROJECTID, $env:BUILD_BUILDID

    Known issues:
        - Write-ConsoleOutput calls inside the foreach use -debug instead of -Type debug,
          causing a parameter binding error at runtime. Fix: replace -debug with -Type debug.
        - 429 retry logic never triggers — see Get-EmergencyReleaseProperty for explanation.
#>

function Get-EmergencyReleaseTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int] $MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelay = 3000
    )

    begin {
        $flagExists               = $false
        $emergencyFlagVariableName = "EMERGENCY_RELEASE_FLAG"
        # Regex matches "Release...Emergency" or "Emergency...Release" (case-insensitive)
        $pattern                  = 'Release.*Emergency|Emergency.*Release'
        $restAttempt              = 1
        $retrySleep               = $false
        $ApiVersion               = "7.1"
        $RequestMethod            = "Get"

        # Build the full ADO API URI for build tags
        $BaseUrl  = "https://dev.azure.com/walmart/{0}" -f $env:SYSTEM_TEAMPROJECTID
        [uri]$FullUri = $BaseUrl + "/_apis/build/builds/{0}/tags" -f $env:BUILD_BUILDID

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
    }

    process {
        do {
            Write-ConsoleOutput "REST API attempt: $($restAttempt)"

            try {
                $response = Invoke-RestMethod @parameters

                # Inspect each tag against the emergency release pattern
                foreach ($value in $response.value) {
                    $regex = [regex]::Matches($value, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

                    if ($regex.Success) {
                        # BUG: -debug should be -Type debug — causes parameter binding error
                        Write-ConsoleOutput "Identified an emergency release tag '$($regex.Value)' to enable the workflow. The emergency release workflow will proceed." -Type debug
                        $flagExists = $true
                    }
                    else {
                        # BUG: -debug should be -Type debug — causes parameter binding error
                        Write-ConsoleOutput "No emergency release tags were identified on the associated pipeline." -Type debug
                        Write-ConsoleOutput "If an emergency workflow needs to be invoked, add a pipeline tag with the words 'Emergency Release'." -Type debug
                    }
                }
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
                    # NOTE: 429 handling never triggers — see Known Issues
                    if ($StatusCode -eq 429) {
                        $RetryDelay = $ResponseHeaders['Retry-After']
                    }
                    Write-ConsoleOutput "Waiting: $($RetryDelay) milliseconds before attempt $($restAttempt)"
                    Start-Sleep -Milliseconds $RetryDelay
                    $retrySleep = $false
                }
            }
        } while ($restAttempt -lt $MaximumRetries)

        # Summarise the result and emit as pipeline variables
        if ($flagExists) {
            Write-ConsoleOutput "The Emergency Release flag exists in the tags for this pipeline." -Type debug
            Write-ConsoleOutput "The Emergency Release property will be set on this pipeline and requires an emergency change request." -Type debug
        }
        else {
            Write-ConsoleOutput "The Emergency Release flag does not exist in the tags for this pipeline." -Type debug
            Write-ConsoleOutput "The Emergency Release property will not be set for this pipeline." -Type debug
        }

        # Emit as both isOutput=true (cross-job) and plain (same-job)
        Write-Host "##vso[task.setvariable variable=$($emergencyFlagVariableName)]$($flagExists)"
        Write-Host "##vso[task.setvariable variable=$($emergencyFlagVariableName);isOutput=true]$($flagExists)"

        return $flagExists
    }

    end {
    }
}
