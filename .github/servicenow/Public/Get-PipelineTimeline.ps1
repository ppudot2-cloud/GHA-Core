<#
.SYNOPSIS
    Retrieves the task/stage timeline records for an Azure DevOps pipeline build.

.DESCRIPTION
    Calls the Azure DevOps Build Timeline REST API to fetch all timeline records for a
    specific build. The timeline includes stages, jobs, steps, checkpoints, and approvals —
    each represented as a record object with type, identifier, state, result, and parentId fields.

    The fetched timeline is saved as a JSON file to the build staging directory for
    post-deployment debugging, then the records array is returned to the caller.

    This function is used internally by Get-ProductionDeploymentStatus (to evaluate stage
    results) and Get-PipelineApprovers (to extract approval information).

    NOTE: The function contains a double .records dereference bug. The API response is
    deserialised into $response (which already has a .records property). The code then
    assigns $timeline = $response.records and returns $timeline.records — which will always
    be $null because the timeline array does not have a .records property. The return
    statement should be: return $timeline (not return $timeline.records).

    NOTE: The output file path uses $PipelineBuildId instead of the resolved $buildId,
    so when PipelineBuildId is not supplied, the filename will contain an empty segment.

.PARAMETER MaximumRetries
    Maximum number of retry attempts if the API call fails. Defaults to 5.

.PARAMETER RetryDelay
    Delay in milliseconds between retry attempts. Defaults to 3000 (3 seconds).

.PARAMETER ProjectName
    The Azure DevOps project name. Defaults to $env:SYSTEM_TEAMPROJECT if not supplied.

.PARAMETER PipelineBuildId
    The build ID to retrieve the timeline for. Defaults to $env:BUILD_BUILDID if not supplied.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Array
    Array of timeline record objects from the build. Each record has properties including:
    id, type, name, identifier, parentId, state, result, startTime, finishTime, task.

    NOTE: Due to the double .records bug, this function currently returns $null.

.EXAMPLE
    Get-PipelineTimeline

    Returns all timeline records for the current pipeline build using environment variables.

.EXAMPLE
    Get-PipelineTimeline -ProjectName "DevSecOps" -PipelineBuildId 12345

    Retrieves the timeline for a specific build in a named project.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Fetch Azure DevOps pipeline timeline for stage/task analysis
    Dependencies: Invoke-AzureDevOpsRestApi

    Known issues:
        - return $timeline.records should be return $timeline — the current code always
          returns $null because $timeline is already the records array.
        - Output file path uses $PipelineBuildId (the parameter, possibly empty) instead
          of $buildId (the resolved value). Fix: use $buildId in the output path.
#>

function Get-PipelineTimeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int] $MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelay = 3000,

        [Parameter(Mandatory = $false)]
        [string] $ProjectName,

        [Parameter(Mandatory = $false)]
        [int] $PipelineBuildId
    )

    begin {
        # Resolve project name: prefer explicit parameter, fall back to environment variable
        if ($PSBoundParameters.ContainsKey('ProjectName')) {
            $project = $ProjectName
        }
        else {
            $project = $env:SYSTEM_TEAMPROJECT
        }

        # Resolve build ID: prefer explicit parameter, fall back to environment variable
        if ($PSBoundParameters.ContainsKey('PipelineBuildId')) {
            $buildId = $PipelineBuildId
        }
        else {
            $buildId = $env:BUILD_BUILDID
        }

        # Output path for saving the timeline JSON (used for post-deployment debugging)
        # NOTE: Uses $PipelineBuildId instead of $buildId — may produce empty filename segment
        $outputPath = "$env:BUILD_STAGINGDIRECTORY/$PipelineBuildId`_timeline.json"

        # Build timeline API path
        $baseUri = "/build/builds/$buildId/timeline"

        $parameters = @{
            "BaseUri"        = $baseUri
            "ProjectName"    = $project
            "RequestMethod"  = "Get"
            "ApiVersion"     = "7.1"
            "MaximumRetries" = 5
            "RetryDelay"     = 3000
        }
    }

    process {
        try {
            $response = Invoke-AzureDevOpsRestApi @parameters

            # Extract the records array from the API response
            $timeline = $response.records

            # Persist timeline to disk for debugging failed deployments
            $timeline | ConvertTo-Json -Depth 100 | Out-File -Path $outputPath -Force

            # BUG: $timeline.records is always $null — should be: return $timeline
            return $timeline.records
        }
        catch {
            throw
        }
        finally {
        }
    }

    end {
    }
}
