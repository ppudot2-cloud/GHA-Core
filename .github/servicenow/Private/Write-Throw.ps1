<#
.SYNOPSIS
    Logs a structured exception and rethrows the error details message as a terminating error.

.DESCRIPTION
    Write-Throw provides a consistent exception-handling entry point for functions in this module.
    When called from a catch block, it:
        1. Opens a collapsible "Caught Exception" group in the Azure DevOps log.
        2. Logs the name of the calling function.
        3. Extracts the .NET exception type from the error record.
        4. For HttpResponseException errors, logs the HTTP method, response code, and
           iterates all non-null string properties on the exception object for diagnostics.
        5. Logs the error details message and the script stack trace at debug level.
        6. Rethrows $Exception.ErrorDetails.Message as a terminating error so the pipeline
           step fails with the server-supplied error body rather than a generic message.

.PARAMETER Caller
    The name of the function that caught the exception. Used as a log label.

.PARAMETER Exception
    The $PSItem error record from the enclosing catch block.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    None. Always terminates via throw.

.EXAMPLE
    catch {
        Write-Throw -Caller "New-ServiceNowChangeRequest" -Exception $PSItem
    }

    Logs the exception details and rethrows the error.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Centralised structured exception logging and rethrow
    Dependencies: Write-ConsoleOutput
#>

function Write-Throw {
    [CmdletBinding()]
    param(
        # Name of the calling function — used as a log label
        [Parameter(Mandatory = $true)]
        [string] $Caller,

        # The $PSItem error record from the enclosing catch block
        [Parameter(Mandatory = $true)]
        [psobject] $Exception
    )

    begin {
        # Open a collapsible group so all exception output is collapsible in ADO logs
        Write-ConsoleOutput "Caught Exception" -Type group
        Write-ConsoleOutput $Caller -Type section

        # Determine the .NET exception type for type-specific handling below
        $exceptionType = $Exception.Exception.GetType().Name
    }

    process {
        if ($exceptionType -eq 'HttpResponseException') {
            # Extract HTTP-specific context for network/API errors
            $requestMethod = $Exception.TargetObject.Method.Method
            $responseCode  = $Exception.Response.StatusCode.value__
            $trace         = $Exception.ScriptStackTrace

            Write-ConsoleOutput ("Request method was: {0}" -f $requestMethod) -Type debug
            Write-ConsoleOutput ("Response code was: {0}"  -f $responseCode)  -Type debug

            # Iterate exception properties and log any non-null string values
            foreach ($object in $Exception.Exception.psobject.Properties) {
                if ($null -ne $object.Value) {
                    # NOTE: The original code iterated over a boolean result from GetType().BaseType.Name -eq 'Object'
                    # which is a bug (iterating a boolean). This should enumerate the object's own properties.
                    # Log the raw value for now as a diagnostic aid.
                    Write-ConsoleOutput "Exception property '$($object.Name)': $($object.Value)" -Type debug
                }
            }
        }

        # Log the error details message (the server-supplied response body for API errors)
        $message = $Exception.ErrorDetails.Message
        Write-Host $Exception.Exception
        Write-ConsoleOutput $trace -Type debug

        # Rethrow with the server-supplied message so the pipeline step fails descriptively
        throw $message
    }

    end {
        # Close the collapsible exception group
        Write-ConsoleOutput -EndGroup
    }
}
