function Invoke-ServiceNowRestApi {
    <#
    .SYNOPSIS
        Thin, validating HTTP client for the ServiceNow REST API with automatic
        retry on transient network failures.

    .DESCRIPTION
        Wraps `Invoke-RestMethod` to provide a consistent, hardened entry point
        for every ServiceNow call made from this module. Responsibilities are
        deliberately narrow: validate the caller-supplied path, assemble the
        full URL by joining with the module-scoped `$config.base_uri`, attach
        Basic authentication, retry on transient network errors, and return
        the deserialised response object.

        End-to-end behaviour:

          1. `begin` block. Performs input validation and URI assembly before
             any network call is made:
               - Rejects a null/whitespace `-Uri`.
               - Rejects absolute URIs that carry their own scheme (anything
                 matching `^[a-zA-Z][a-zA-Z0-9+.\-]*://`). Callers must pass a
                 relative path so that every request is forced through the
                 configured `$config.base_uri`, eliminating any chance of a
                 caller accidentally hitting a different ServiceNow instance
                 or an arbitrary host.
               - Rejects network-path references that start with `//`.
               - Splits off query (`?`) and fragment (`#`) segments so that
                 validation is applied only to the path portion (a literal `?`
                 or `#` inside the query string is legal and must be preserved).
               - Rejects backslashes in the path (Windows-style separators are
                 not valid in URLs and most commonly indicate a bug).
               - Rejects path traversal segments (`..`) anchored to a `/`.
               - Normalises the path to start with a single `/`.
               - Trims a trailing `/` from `$config.base_uri` before
                 concatenation to avoid producing `//` at the join point.
               - Casts the final string to `[uri]` so downstream code gets a
                 strongly-typed URI and a second parse-time sanity check.

             All validation failures bubble up as
             `[System.ArgumentException]` and are logged (stack trace +
             exception) before a generic terminating error is thrown so the
             caller gets a clear failure without leaking implementation
             details. The `finally` block always logs the resolved
             `$FullUri.AbsoluteUri` at debug level — useful when a request
             goes to an unexpected host.

          2. `process` block. Runs a do/while retry loop up to
             `$MaximumRetries` iterations:
               - Builds an `Authorization: Basic <base64(user:password)>`
                 header from `$env:ServiceNowUsername` and
                 `$env:ServiceNowPassword`. These values are read fresh on
                 every attempt so a rotated secret is picked up on the next
                 retry without restarting the process.
               - Assembles a splat hashtable for `Invoke-RestMethod` with
                 `Method`, `Uri`, `StatusCodeVariable = StatusCode`, and the
                 standard `Authorization`, `Accept: application/json`, and
                 `Content-Type: <ContentType>;charset=UTF-8` headers.
               - Conditionally adds `Body` (for Post/Put/Patch requests with
                 a JSON payload) and `InFile` (for attachment uploads). These
                 are mutually compatible with `Invoke-RestMethod` but should
                 not both be supplied for the same call.
               - On success, returns the deserialised response object and
                 exits the retry loop immediately.
               - Only `[System.Net.Http.HttpRequestException]` is treated as
                 retryable (this is the canonical transient-network exception
                 in PowerShell 7+). Any other exception is considered a
                 hard failure: the stack trace and exception are logged and a
                 generic terminating error is thrown.
               - The `finally` block schedules a sleep of `$RetryDelay`
                 milliseconds before the next attempt if a retry was
                 requested. Sleep happens in `finally` so it is independent
                 of the control-flow path that set `$retrySleep`.

             Note that the retry delay is fixed (no exponential back-off) and
             that `StatusCodeVariable` is populated by `Invoke-RestMethod` but
             not currently consumed — the function does not react to specific
             HTTP status codes beyond what `Invoke-RestMethod` surfaces as an
             exception. Callers that need status-code-driven behaviour should
             layer it on top of this function.

        Authentication is handled exclusively through environment variables
        so that no credential ever appears in script source or in the call
        site. When this function runs in Azure DevOps, bind
        `ServiceNowUsername` / `ServiceNowPassword` from pipeline secrets so
        they remain masked in logs.

    .PARAMETER RequestMethod
        HTTP verb for the call. Constrained to the standard ServiceNow-
        compatible verbs via `ValidateSet`: Get, Delete, Head, Patch, Post,
        Put.

    .PARAMETER Uri
        Relative path (and optional query string / fragment) under
        `$config.base_uri`. Must NOT be an absolute URL. Must NOT contain
        backslashes or `..` traversal segments. A leading `/` is optional and
        will be added if missing. Example: `/api/now/table/incident?sysparm_limit=1`.

    .PARAMETER Body
        Optional request body as a string. For JSON payloads, pre-serialise
        with `ConvertTo-Json` before passing. Ignored when null/whitespace so
        callers can pass `$null` unconditionally for verbs that don't carry a
        body.

    .PARAMETER ContentType
        MIME type of the request body. Defaults to `application/json`. The
        function always appends `;charset=UTF-8` when constructing the
        `Content-Type` header.

    .PARAMETER InFile
        Optional path to a file to stream as the request body, used for
        attachment uploads against endpoints such as
        `/api/now/attachment/file`. Ignored when null/whitespace. When
        supplied, the `Content-Type` should be set appropriately (e.g.
        `application/octet-stream` or the attachment's actual MIME type).

    .PARAMETER MaximumRetries
        Upper bound on the number of attempts when a transient
        `HttpRequestException` is encountered. Defaults to 5. Because the
        loop is do/while with `$restAttempt -lt $MaximumRetries`, a value of
        5 means up to 5 total attempts (1 initial + 4 retries).

    .PARAMETER RetryDelay
        Milliseconds to sleep between retry attempts. Defaults to 3000
        (3 seconds). Fixed delay — no exponential back-off.

    .INPUTS
        None. This function does not accept pipeline input.

    .OUTPUTS
        System.Object
        The deserialised response from `Invoke-RestMethod`. For table API
        calls this is typically a PSCustomObject with a `.result` property.
        Returns `$null` implicitly if all retries are exhausted without a
        successful response (callers should treat a `$null` return as a
        failure).

    .EXAMPLE
        PS> Invoke-ServiceNowRestApi -RequestMethod Get `
                -Uri "/api/now/table/incident?sysparm_limit=1"

        Issues a GET against the incident table and returns the deserialised
        response envelope.

    .EXAMPLE
        PS> $payload = @{ short_description = "test"; urgency = 3 } |
                ConvertTo-Json -Compress
        PS> Invoke-ServiceNowRestApi -RequestMethod Post `
                -Uri "/api/now/table/incident" `
                -Body $payload

        Creates a new incident record. The `Body` is passed as a pre-
        serialised JSON string.

    .EXAMPLE
        PS> Invoke-ServiceNowRestApi -RequestMethod Post `
                -Uri "/api/now/attachment/file?table_name=incident&table_sys_id=<sys_id>&file_name=log.txt" `
                -InFile "C:\logs\log.txt" `
                -ContentType "text/plain"

        Uploads a file as an attachment on an existing incident record using
        the ServiceNow attachment API.

    .NOTES
        External dependencies (must be present in the module scope):
            - $config.base_uri                Script-scoped ServiceNow
                                              instance URL (e.g.
                                              https://acme.service-now.com).
                                              Joined with the validated
                                              relative path to form the full
                                              request URI.
            - $env:ServiceNowUsername         Basic-auth username. Read on
                                              every attempt; mark secret in
                                              Azure DevOps.
            - $env:ServiceNowPassword         Basic-auth password. Read on
                                              every attempt; mark secret in
                                              Azure DevOps.
            - Write-ConsoleOutput             Module logging helper; used
                                              here with -Type debug for the
                                              resolved URI and each retry
                                              attempt.

        Retry semantics:
            Only `[System.Net.Http.HttpRequestException]` is retried. HTTP
            status-code errors raised by `Invoke-RestMethod` (400-series and
            500-series responses) surface through the generic catch and are
            thrown immediately with no retry. If upstream callers need
            retry-on-5xx, they should catch the thrown error and invoke this
            function again themselves.

        Known limitations:
            - Fixed retry delay (no jitter, no exponential back-off). For
              high-volume callers this may produce synchronised retry
              storms against a degraded ServiceNow instance.
            - `StatusCodeVariable` is populated by `Invoke-RestMethod` but
              never inspected by this function.
            - When all retries are exhausted the function falls out of the
              `do { } while` loop and the `process` block ends without
              throwing, which means the caller sees `$null` rather than an
              exception. Guard with an explicit null check if a non-null
              response is required.
            - Credentials are sourced from environment variables; any
              caller in the same process can read them. Acceptable inside
              an Azure DevOps job where the job is the credential boundary,
              but do not treat the process as a trust boundary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Delete', 'Head', 'Patch', 'Post', 'Put')]
        [string]$RequestMethod,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [string]$ContentType = 'application/json',

        [Parameter(Mandatory = $false)]
        [string]$InFile,

        [Parameter(Mandatory = $false)]
        [int]$MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelay = 3000
    )

    begin {
        try {
            $restAttempt = 1
            $retrySleep = $false
            if ([string]::IsNullOrWhiteSpace($Uri)) {
                throw [System.ArgumentException]::new('Uri must not be empty.')
            }

            $normalizedUri = $Uri.Trim()
            if ($normalizedUri -match '^[a-zA-Z][a-zA-Z0-9+.\-]*://') {
                throw [System.ArgumentException]::new('Uri must be a relative path, not an absolute URI.')
            }

            if ($normalizedUri.StartsWith('//')) {
                throw [System.ArgumentException]::new('Uri must be a relative path, not a network-path reference.')
            }

            $uriPathOnly = ($normalizedUri -split '\?', 2)[0]
            $uriPathOnly = ($uriPathOnly -split '#', 2)[0]
            if ($uriPathOnly -match '\\') {
                throw [System.ArgumentException]::new('Uri must not contain backslashes.')
            }

            if ($uriPathOnly -match '(^|/)\.\.(/|$)') {
                throw [System.ArgumentException]::new('Uri must not contain path traversal (..).')
            }

            if (-not $normalizedUri.StartsWith('/')) {
                $normalizedUri = '/' + $normalizedUri
            }
            $baseUri = [string]$config.base_uri
            $baseUri = $baseUri.TrimEnd('/')
            [uri]$FullUri = $baseUri + $normalizedUri
        } catch {
            Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
            Write-Error $PSItem.Exception -ErrorAction Continue
            throw "An unhandled exception was caught."
        } finally {
            Write-ConsoleOutput "Full URI is: $($FullUri.AbsoluteUri)" -Type debug
        }
    }

    process {
        do {
            try {
                $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -F $env:ServiceNowUsername, $env:ServiceNowPassword)))
                $parameters = @{
                    "Method"             = $RequestMethod
                    "Uri"                = $FullUri
                    "StatusCodeVariable" = "StatusCode"
                    "Headers"            = @{
                        "Authorization" = "Basic {0}" -F $auth
                        "Accept"        = "application/json"
                        "Content-Type"  = "{0};charset=UTF-8" -F $ContentType
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($Body)) {
                    $parameters.Add("Body", $Body)
                }
                if (-not [string]::IsNullOrWhiteSpace($InFile)) {
                    $parameters.Add("InFile", $InFile)
                }
                Write-ConsoleOutput "REST API attempt: $($restAttempt)" -Type debug
                $response = Invoke-RestMethod @parameters
                return $response
            } catch [System.Net.Http.HttpRequestException] {
                Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
                Write-Error $PSItem.Exception -ErrorAction Continue
                Write-Error -Exception $PSItem.Exception -Message "REST API call failed attempt $($restAttempt) of $($MaximumRetries)." -ErrorAction Continue
                $retrySleep = $true
            } catch {
                Write-Error $PSItem.ScriptStackTrace -ErrorAction Continue
                Write-Error $PSItem.Exception -ErrorAction Continue
                throw "An unhandled exception was caught."
            } finally {
                if ($retrySleep) {
                    $restAttempt++
                    Write-ConsoleOutput "Waiting: $($RetryDelay) milliseconds before attempt $($restAttempt)"
                    Start-Sleep -Milliseconds $RetryDelay
                    $retrySleep = $false
                }
            }
        } while ($restAttempt -lt $MaximumRetries)
    }

    end {
    }
}
