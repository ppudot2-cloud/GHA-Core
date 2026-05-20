<#
.SYNOPSIS
    Formats and logs exception details for a failed Azure DevOps REST API call.

.DESCRIPTION
    Write-AzureDevOpsRestApiException is an internal helper called from within
    Invoke-AzureDevOpsRestApi when a request fails. It logs the attempt number,
    stack trace, exception object, and error details message to the pipeline console,
    then sleeps for the configured retry delay before the next attempt.

.PARAMETER MaximumRetries
    The total maximum number of attempts configured on the calling function.
    Used in the log message to show progress (attempt N of MaximumRetries).

.PARAMETER RetryDelay
    Milliseconds to pause after logging before the next retry attempt.

.INPUTS
    None. Does not accept pipeline input.

.OUTPUTS
    None. Side effects: writes to console and sleeps.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Centralised exception logging for Invoke-AzureDevOpsRestApi retry loop
    Dependencies: Write-ConsoleOutput, $retryCount (module-scoped variable from caller)
#>
function Write-AzureDevOpsRestApiException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int] $MaximumRetries,

        [Parameter(Mandatory = $true)]
        [int] $RetryDelay
    )

    begin {
        # Open a collapsible group to keep exception noise collapsible in ADO logs
        Write-ConsoleOutput "Exception on attempt $($retryCount) of $($MaximumRetries)" -Type group
    }

    process {
        # Log all three error record components for maximum diagnosability
        Write-Error -Exception $PSItem.ScriptStackTrace  -ErrorAction Continue
        Write-Error -Exception $PSItem.Exception         -ErrorAction Continue
        Write-Error -Exception $PSItem.ErrorDetails.Message -Message "Attempt ($($retryCount)) of ($($MaximumRetries)) REST API call failed." -ErrorAction Continue
    }

    end {
        # Pause before the next retry attempt
        Write-ConsoleOutput "Pausing for ($($RetryDelay / 1000)) seconds before re-attempting the REST API call." -Type debug
        Start-Sleep -Milliseconds $RetryDelay
    }
}


<#
.SYNOPSIS
    Invokes a REST API request against Azure DevOps and returns the deserialised response.

.DESCRIPTION
    Provides a hardened, retrying HTTP client for all Azure DevOps REST API calls in
    this module. It constructs the full request URI from the supplied base path and
    project name, attaches Bearer token authentication from $env:SYSTEM_ACCESSTOKEN,
    and runs a do/while retry loop up to MaximumRetries attempts.

    End-to-end behaviour:

        1. begin block — Captures the call stack for diagnostics, initialises retry
           state flags ($retryCount, $success, $content, $retry), and constructs the
           full URL:
               https://dev.azure.com/walmart/{project}/_apis{BaseUri}
           Logs all initial state values for debugging.

        2. process block — Retry loop using Invoke-WebRequest with SkipHttpErrorCheck
           so HTTP error codes are returned as response objects rather than exceptions.
           On each attempt:
               - If the status code is in $successCodes (200, 201, 204): marks $success.
               - If the status code is also in $successContentCodes (200, 201): marks $content.
               - On HttpRequestException: creates a new HttpRequestException (does not retry
                 via the standard catch path — the $success/$retry flags drive retry logic).
               - The finally block sets $retry = $false on success, $retry = $true on failure.
           After the loop:
               - $success + $output -> returns deserialised JSON.
               - $success + no output (204) -> returns $null.
               - Max retries exhausted or unhandled -> throws.

        3. end block — Empty.

.PARAMETER BaseUri
    The API path segment appended to the project base URL.
    Example: "/build/builds/12345/timeline"

.PARAMETER ProjectName
    The Azure DevOps project name. Spaces are URL-encoded to %20.

.PARAMETER RequestMethod
    HTTP verb. One of: Default, Delete, Get, Head, Merge, Options, Patch, Post, Put, Trace.

.PARAMETER ApiVersion
    Azure DevOps API version string. Defaults to "7.1".

.PARAMETER MaximumRetries
    Maximum number of retry attempts. Defaults to 5.

.PARAMETER RetryDelay
    Milliseconds between retry attempts. Defaults to 3000.

.INPUTS
    None. Does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The deserialised JSON response body, or $null for 204 No Content responses.

.EXAMPLE
    Invoke-AzureDevOpsRestApi -BaseUri "/build/builds/98765/timeline" `
        -ProjectName "MyProject" -RequestMethod Get

    Fetches the build timeline for build 98765.

.EXAMPLE
    Invoke-AzureDevOpsRestApi -BaseUri "/build/builds/98765/properties" `
        -ProjectName "DevSecOps" -RequestMethod Patch -MaximumRetries 3

    Updates build properties with 3 maximum attempts.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Hardened Azure DevOps REST API client with retry logic
    Dependencies: Write-ConsoleOutput, $env:SYSTEM_ACCESSTOKEN

    Known issues:
        - The HttpRequestException catch creates a new exception object but does not
          set $retry = $true or increment $retryCount, so the loop may not retry as
          intended for genuine transient network failures.
        - The 204 (No Content) branch throws inside the try block instead of simply
          setting $content = $false, which may cause misleading error messages.
#>
function Invoke-AzureDevOpsRestApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $BaseUri,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Default", "Delete", "Get", "Head", "Merge", "Options", "Patch", "Post", "Put", "Trace")]
        [string] $RequestMethod,

        [Parameter(Mandatory = $false)]
        [string] $ApiVersion = "7.1",

        [Parameter(Mandatory = $false)]
        [int] $MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelay = 3000
    )

    begin {
        # Capture the current call stack to identify which function triggered this call
        $callStack = Get-PSCallStack | Select-Object -Property *
        foreach ($object in $callStack) {
            if ($object.Position.Text -like "*Invoke-AzureDevOpsRestApi*") {
                $callStack = $object
            }
        }

        # Initialise retry state
        $retryCount = 0
        $success    = $false
        $content    = $false
        $retry      = $true

        # HTTP status codes that indicate a successful response
        $successCodes        = 200, 201, 204
        # HTTP status codes that include a response body (204 = No Content has no body)
        $successContentCodes = 200, 201

        # URL-encode spaces in project name, then build the full ADO API URL
        $project  = $ProjectName.Replace(' ', '%20')
        $baseUrl  = "https://dev.azure.com/walmart/" + $project + "/_apis"
        $fullUri  = $baseUrl + $BaseUri

        # Assemble request parameters with Bearer token authentication
        $parameters = @{
            "Method"             = $RequestMethod
            "Uri"                = $fullUri
            "SkipHttpErrorCheck" = $true   # Prevents Invoke-WebRequest from throwing on 4xx/5xx
            "Headers"            = @{
                "Authorization"   = "Bearer {0}" -f $env:SYSTEM_ACCESSTOKEN
                "Accept"          = "application/json;api-version={0}" -f $ApiVersion
                "Content-Type"    = "application/json;charset=utf-8"
                "Cache-Control"   = "no-cache"
                "Accept-Language" = "en-US"
            }
        }

        # Log initial state for debugging (visible only when SYSTEM_DEBUG is enabled)
        Write-ConsoleOutput "The full URI is: $($fullUri)"
        Write-ConsoleOutput "The parameters are: $($parameters)"
        Write-ConsoleOutput "The call stack is: $($callStack)"
        Write-ConsoleOutput "The success codes are: $($successCodes)"
        Write-ConsoleOutput "The success content codes are: $($successContentCodes)"
        Write-ConsoleOutput "The retry count is: $($retryCount)"
        Write-ConsoleOutput "The success flag is: $($success)"
        Write-ConsoleOutput "The content flag is: $($content)"
        Write-ConsoleOutput "The retry flag is: $($retry)"
        Write-ConsoleOutput "The output flag is: $($output)"
        Write-ConsoleOutput "The API version is Set to: $($ApiVersion)"
    }

    process {
        do {
            $retryCount++
            Write-ConsoleOutput "Azure DevOps REST API attempt: $($retryCount) of $($MaximumRetries)" -Type group

            try {
                $response = Invoke-WebRequest @parameters

                if ($response.StatusCode -in $successCodes) {
                    $success = $true
                    if ($response.StatusCode -in $successContentCodes) {
                        # 200/201: response has a JSON body to deserialise
                        $content = $true
                    }
                    else {
                        # 204 No Content: success but no body — throw to exit try cleanly
                        throw
                    }
                }
                else {
                    # Non-success status code: throw to trigger retry logic
                    throw
                }
            }
            catch [System.Net.Http.HttpRequestException] {
                # Transient network error — log it; retry logic is driven by $success/$retry flags
                [System.Net.Http.HttpRequestException]::New([string]"Response status code does not indicate success.", [string]$response.Content)
            }
            finally {
                # Update retry flag based on whether the request succeeded
                if (-not $success) {
                    $retry = $true
                }
                if ($success) {
                    $retry = $false
                    # Determine whether a response body is available
                    if ($content) { $output = $true  }
                    else          { $output = $false }
                }
            }

        } while (($retryCount -lt $MaximumRetries) -and ($retry))

        # Return the appropriate result after the retry loop completes
        if ($success -and $output) {
            # Successful response with JSON body — log and return deserialised object
            Write-ConsoleOutput $response -ParsedGroupName "Response payload from Azure DevOps REST API" -ObjectOutput
            return $response.Content | ConvertFrom-Json -Depth 100
        }
        elseif ($success -and -not $output) {
            # 204 No Content — success but nothing to return
            Write-ConsoleOutput "There was no content in the response." -Type debug
            return $null
        }
        elseif (-not $retry) {
            # Retry limit reached
            throw [System.Exception]::New("Maximum retries ($($MaximumRetries)) has been reached.")
        }
        else {
            # Unexpected state
            throw [System.Exception]::New("An unhandled exception occurred.")
        }

        # Close the attempt group (note: this line is unreachable after throw/return above)
        Write-ConsoleOutput -EndGroup
    }

    end {
    }
}
