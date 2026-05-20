<#
.SYNOPSIS
    Stamps the current Azure DevOps pipeline build with 13 custom properties linking it
    to the active ServiceNow change ticket and capturing deployment metadata.

.DESCRIPTION
    PATCHes the Azure DevOps Build Properties API to store the following metadata on the
    current pipeline run:
        - changeTicketUrl               — ServiceNow portal URL for the change ticket
        - changeTicketNumber            — ServiceNow change request number (e.g. CHG0012345)
        - deploymentApprover            — Display name of the ADO user who triggered the build
        - deploymentApproverEmail       — Email of the triggering user
        - deploymentApproverUserGuid    — AAD object ID of the triggering user
        - deploymentPipelineTriggerReason — How the build was triggered (Manual, CI, etc.)
        - deploymentGitCommitAuthor     — Git commit author of the build source
        - deploymentGitCommitId         — Full git commit SHA
        - deploymentGitRepositoryName   — Repository name
        - deploymentGitBranchRef        — Full git branch ref (e.g. refs/heads/main)
        - deploymentPipelineDefinitionId   — Pipeline definition ID
        - deploymentPipelineDefinitionName — Pipeline definition name
        - deploymentPipelineDefinitionPath — Pipeline definition folder path

    These properties persist on the build record and can be queried via the ADO API or
    displayed in the build's Properties tab in the portal.

    Called by Close-ServiceNowChangeRequest to record deployment context before closing
    the change ticket.

    NOTE: The changeTicketUrl property value uses ($config.base_uri) (parentheses, not
    $()) which is interpreted as a subexpression containing $config — not as string
    interpolation. The result will be a literal string "($config.base_uri)/nav_to.do..."
    rather than the resolved URL. Fix: use $($config.base_uri).

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    None. Side effects: one PATCH request to Azure DevOps setting 13 build properties.
    Logs each property with its expected and actual value after the request.

.EXAMPLE
    Set-PipelineProperties

    Sets all 13 build properties for the current pipeline run. Typically called from
    Close-ServiceNowChangeRequest.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Persist change ticket and deployment metadata as ADO build properties
    Dependencies: Write-ConsoleOutput, $global:change_record (sys_id, number),
                  $global:config (base_uri), $env:SYSTEM_TEAMPROJECT, $env:BUILD_BUILDID,
                  $env:SYSTEM_DEFINITIONID, $env:BUILD_DEFINITIONNAME, $env:SYSTEM_ACCESSTOKEN,
                  $env:BUILD_REQUESTEDFOR, $env:BUILD_REQUESTEDFOREMAIL,
                  $env:BUILD_REQUESTEDFORID, $env:BUILD_REASON,
                  $env:BUILD_SOURCEVERSIONAUTHOR, $env:BUILD_SOURCEVERSION,
                  $env:BUILD_REPOSITORY_NAME, $env:BUILD_SOURCEBRANCH,
                  $env:BUILD_DEFINITIONFOLDERPATH

    Known issues:
        - changeTicketUrl uses ($config.base_uri) instead of $($config.base_uri), so the
          URL is never interpolated — the literal text "($config.base_uri)" appears instead.
        - $parameters.Body serialisation uses ConvertTo-Json -InputObject which may wrap
          the array differently than expected in some PowerShell versions.
#>

function Set-PipelineProperties {
    [CmdletBinding()]
    param()

    begin {
        Write-ConsoleOutput "Setting pipeline run properties" -Type section

        # Capture pipeline identity values for use in the request body
        $projectId              = $env:SYSTEM_TEAMPROJECT -replace " ", "%20"
        $buildId                = $env:BUILD_BUILDID
        $pipelineDefinitionName = $env:BUILD_DEFINITIONNAME
        $pipelineDefinitionId   = $env:SYSTEM_DEFINITIONID
        $ApiVersion             = "7.1"

        # Construct the full ADO build properties endpoint URL
        $BaseUrl  = "https://dev.azure.com/walmart/{0}" -f $projectId
        [uri]$FullUri = $BaseUrl + "/_apis/build/builds/{0}/properties" -f $buildId

        $parameters = @{
            "Method"  = "Patch"
            "Uri"     = $FullUri
            "Headers" = @{
                "Authorization" = "Bearer {0}" -f $env:SYSTEM_ACCESSTOKEN
                "Accept"        = "application/json;api-version={0}" -f $ApiVersion
                "Content-Type"  = "application/json-patch+json;charset=utf-8"
                "Cache-Control" = "no-cache"
            }
            # JSON-Patch array — each entry adds/updates one build property
            "Body" = @(
                # BUG: ($config.base_uri) is not interpolated — should be $($config.base_uri)
                @{ "op" = "add"; "path" = "/changeTicketUrl";    "value" = "($config.base_uri)/nav_to.do?uri=change_request.do?sys_id={0}" -f $change_record.sys_id },
                @{ "op" = "add"; "path" = "/changeTicketNumber"; "value" = $change_record.number },
                @{ "op" = "add"; "path" = "/deploymentApprover";              "value" = $env:BUILD_REQUESTEDFOR },
                @{ "op" = "add"; "path" = "/deploymentApproverEmail";         "value" = $env:BUILD_REQUESTEDFOREMAIL },
                @{ "op" = "add"; "path" = "/deploymentApproverUserGuid";      "value" = $env:BUILD_REQUESTEDFORID },
                @{ "op" = "add"; "path" = "/deploymentPipelineTriggerReason"; "value" = $env:BUILD_REASON },
                @{ "op" = "add"; "path" = "/deploymentGitCommitAuthor";       "value" = $env:BUILD_SOURCEVERSIONAUTHOR },
                @{ "op" = "add"; "path" = "/deploymentGitCommitId";           "value" = $env:BUILD_SOURCEVERSION },
                @{ "op" = "add"; "path" = "/deploymentGitRepositoryName";     "value" = $env:BUILD_REPOSITORY_NAME },
                @{ "op" = "add"; "path" = "/deploymentGitBranchRef";          "value" = $env:BUILD_SOURCEBRANCH },
                @{ "op" = "add"; "path" = "/deploymentPipelineDefinitionId";  "value" = $pipelineDefinitionId },
                @{ "op" = "add"; "path" = "/deploymentPipelineDefinitionName";"value" = $pipelineDefinitionName },
                @{ "op" = "add"; "path" = "/deploymentPipelineDefinitionPath";"value" = $env:BUILD_DEFINITIONFOLDERPATH }
            )
        }
    }

    process {
        Write-ConsoleOutput "Request property values (Pipeline: $($pipelineDefinitionName), Definition: $($pipelineDefinitionId), Run ID: $($buildId))" -Type group

        # Log each property name and value before sending
        foreach ($object in $parameters.Body) {
            "Property: $($object.path.TrimStart('/')), Value: $($object.value)"
        }

        Write-ConsoleOutput -EndGroup

        # Serialise the JSON-Patch body array
        $parameters.Body = $parameters.Body | ConvertTo-Json -InputObject $parameters.Body

        Write-ConsoleOutput "REST API Request URI: $($parameters.Uri.AbsoluteUri)" -Type section
        Write-ConsoleOutput "REST API Request Version: $($ApiVersion)" -Type section
        Write-ConsoleOutput "Sending API request to set pipeline properties" -Type section

        $response = Invoke-WebRequest @parameters
        $content  = ($response | ConvertFrom-Json -Depth 100).value
    }

    end {
        # Enumerate the properties returned by the API and verify each one was set correctly
        $pipelineProperties = $content.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' }

        # Build a lookup of what we attempted to set
        $propertiesSetByRequest = [ordered]@{}
        $parameters.Body | ConvertFrom-Json -Depth 100 | ForEach-Object {
            $propertiesSetByRequest[$_.path.TrimStart('/')] = $_.value
        }

        Write-ConsoleOutput "Listing build properties" -Type group

        foreach ($property in $pipelineProperties) {
            if ($null -ne $propertiesSetByRequest[$property.Name]) {
                $expectedValue = $propertiesSetByRequest[$property.Name]
                $actualValue   = $property.Value.'$value'

                if ($expectedValue -eq $actualValue) {
                    Write-ConsoleOutput "Property: $($property.Name) value was successfully set (Value: $actualValue)" -Type section
                }
                else {
                    # Mismatch — log for investigation
                    Write-ConsoleOutput "Property: $($property.Name) value mismatch (Expected: $expectedValue, Actual: $actualValue)" -Type section
                }
            }
            else {
                # Property exists on the build but was not set by this function call
                Write-ConsoleOutput "Property: $($property.Name) value was not set by this function (Value: $($property.Value.'$value'))" -Type section
            }
        }

        Write-ConsoleOutput -EndGroup
    }
}
