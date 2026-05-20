<#
.SYNOPSIS
    Retrieves deployment stage approvers from an Azure DevOps pipeline timeline and logs
    their details as work notes on the active ServiceNow Change Request.

.DESCRIPTION
    Queries the Azure DevOps Build Timeline REST API to identify all deployment stages
    (DEV, INTG, UAT, PERF, PROD, TRNG) in the pipeline, then follows the hierarchy:
        Stage -> Checkpoint -> Checkpoint.Approval -> Approvals API (actual approver identity)

    For each stage with an approval, the function calls the Azure DevOps Approvals API
    to retrieve the actual approver (display name, email) and the approval timestamp.
    It then creates a ServiceNow work note for each stage containing these details.

    The function runs a do/while retry loop directly using Invoke-RestMethod with a
    Bearer token header (rather than delegating to Invoke-AzureDevOpsRestApi).

    NOTE: The begin block contains a URI doubling bug. $global:baseUri is first set to
    the ADO base URL, then immediately overwritten with just the path segment — so both
    assignments are wrong and the final $global:fullUri concatenates the path with itself,
    producing an invalid URL. The fix is to construct the full timeline URI directly.

.PARAMETER MaximumRetries
    Maximum number of retry attempts if the REST API call fails. Defaults to 5.

.PARAMETER RetryDelay
    Delay in milliseconds between retry attempts. Defaults to 3000 (3 seconds).

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Collections.Hashtable
    A hashtable keyed by stage ID, where each value is the stage object augmented with
    'checkpoint', 'approval', and 'approvers' note properties.

.EXAMPLE
    Get-PipelineApprovers

    Retrieves all deployment stage approvers and adds work notes to the active change request.

.EXAMPLE
    $stageApprovals = Get-PipelineApprovers -MaximumRetries 8 -RetryDelay 5000
    $stageApprovals.Keys | ForEach-Object { $stageApprovals[$_].approvers }

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Extract ADO pipeline approver details for ServiceNow change request work notes
    Dependencies: Add-ServiceNowChangeWorkNotes, Write-ConsoleOutput,
                  $env:SYSTEM_ACCESSTOKEN, $env:SYSTEM_TEAMPROJECTID, $env:BUILD_BUILDID,
                  $global:change_record (sys_id), $global:config (base_uri)

    Known issues:
        - URI doubling bug: $global:baseUri is set to a full URL then immediately overwritten
          with just a path segment; the UriBuilder then appends the path to itself, producing
          an invalid URL (e.g. "https://dev.azure.com/build/builds/123/timeline/build/builds/123/timeline").
        - Null guard missing: $stages[$stage].checkpoint and .approval may be null if a stage
          has no checkpoint or approval, causing Add-Member to throw on a null object.
        - The Approvals API URI uses $global:baseUri (the path-only value) rather than the
          project-scoped ADO base URL.
#>

function Get-PipelineApprovers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int] $MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelay = 3000
    )

    begin {
        $retryCount = 0

        # BUG: $global:baseUri is overwritten immediately — both lines are wrong.
        # Line 1 sets a full ADO base URL; line 2 overwrites it with just the path segment.
        # The UriBuilder then doubles the path in the full URI.
        $global:baseUri = "https://walmart.azure.com/$($env:SYSTEM_TEAMPROJECTID)/_apis/"
        $global:baseUri = "build/builds/$($env:BUILD_BUILDID)/timeline"

        # Construct the full timeline URI (note: $global:baseUri + $global:baseUri is wrong)
        $global:fullUri = [System.UriBuilder]::New(
            "https",
            "dev.azure.com",
            443,
            $global:baseUri + $global:baseUri,   # BUG: path duplicated
            "?api-version=7.1-preview.2"
        )

        $fullUri.Uri.AbsoluteUri

        # Standard ADO Bearer token headers
        $headers = @{
            "Authorization" = "Bearer $($env:SYSTEM_ACCESSTOKEN)"
            "Accept"        = "application/json"
            "Content-Type"  = "application/json"
        }

        # Accumulate deployment stages keyed by their timeline record ID
        $stages = @{}
    }

    process {
        do {
            $retryCount++
            Write-ConsoleOutput "REST API attempt: $($retryCount)"

            try {
                # Fetch the full build timeline
                $response = Invoke-RestMethod -Uri $fullUri.Uri.AbsoluteUri -Method Get -Headers $headers
                $timeline = $response.records

                # -------------------------------------------------------
                # Pass 1: Collect all deployment stages from the timeline
                # -------------------------------------------------------
                foreach ($object in $timeline) {
                    if (
                        ($object.type -eq 'Stage') -and
                        ($object.identifier -match 'stageDeploy*' -or
                         $object.identifier -like '*DEV*'  -or
                         $object.identifier -like '*INTG*' -or
                         $object.identifier -like '*UAT*'  -or
                         $object.identifier -like '*PERF*' -or
                         $object.identifier -like '*PROD*' -or
                         $object.identifier -like '*TRNG*')
                    ) {
                        $stages[$object.id] = $object
                    }
                }

                # -------------------------------------------------------
                # Pass 2: Attach Checkpoint records to each deployment stage
                # -------------------------------------------------------
                foreach ($stage in $stages.Keys) {
                    foreach ($object in $timeline) {
                        if ($object.type -eq 'Checkpoint' -and
                            $object.name -eq 'Checkpoint'  -and
                            $object.parentId -eq $stages[$stage].id) {
                            $stages[$stage] | Add-Member -Name 'checkpoint' -Type NoteProperty -Value $object
                        }
                    }
                }

                # -------------------------------------------------------
                # Pass 3: Attach Checkpoint.Approval records to each stage
                # -------------------------------------------------------
                foreach ($stage in $stages.Keys) {
                    foreach ($object in $timeline) {
                        if ($object.type -eq 'Checkpoint.Approval' -and
                            $object.name -eq 'Checkpoint.Approval' -and
                            $object.parentId -eq $stages[$stage].checkpoint.id) {
                            $stages[$stage] | Add-Member -Name 'approval' -Type NoteProperty -Value $object
                        }
                    }
                }

                # -------------------------------------------------------
                # Pass 4: Call the Approvals API to get the actual approver identity
                # -------------------------------------------------------
                foreach ($stage in $stages.Keys) {
                    # Build the approvals detail URI for this stage's approval record
                    $fullUri = [System.UriBuilder]::New(
                        "https",
                        "dev.azure.com",
                        443,
                        "$global:baseUri/pipelines/approvals/$($stages[$stage].approval.id)",
                        "?`$expand=steps&api-version=7.1-preview.1"
                    )

                    $response = Invoke-RestMethod -Uri $fullUri.Uri.AbsoluteUri -Method Get -Headers $headers
                    $content  = $response.steps   # steps[].actualApprover contains identity info

                    $stages[$stage] | Add-Member -Name 'approvers' -Type NoteProperty -Value $content
                }

                # -------------------------------------------------------
                # Pass 5: Create ServiceNow work notes for each approved stage
                # -------------------------------------------------------
                foreach ($key in $stages.Keys) {
                    $worknote  = "Stage Identifier: $($stages[$key].identifier)`n"
                    $worknote += "Approved at: $($stages[$key].approvers.lastModifiedOn)`n"
                    $worknote += "Approved by display name: $($stages[$key].approvers.actualApprover.displayName)`n"
                    $worknote += "Approved by email: $($stages[$key].approvers.actualApprover.uniqueName)`n"

                    Write-ConsoleOutput "Adding Stage approval work note: "
                    $worknote

                    Add-ServiceNowChangeWorkNotes -WorkNote $worknote
                }

                return $stages
            }
            catch [System.Net.WebException] {
                Write-Error -Exception $PSItem.ScriptStackTrace  -ErrorAction Continue
                Write-Error -Exception $PSItem.Exception         -ErrorAction Continue
                Write-Error -Exception $PSItem.ErrorDetails.Message -Message "REST API call failed. Retry count is set to $($MaximumRetries)." -ErrorAction Continue
                Start-Sleep -Milliseconds $RetryDelay
            }
            catch {
                Write-Error $PSItem.ScriptStackTrace  -ErrorAction Continue
                Write-Error $PSItem.Exception         -ErrorAction Continue
                Write-Error $PSItem.ErrorDetails.Message -Message "REST API call failed. Retry count is set to $($MaximumRetries)." -ErrorAction Continue
                Start-Sleep -Milliseconds $RetryDelay
            }
            finally {
                Write-ConsoleOutput "The ServiceNow Change Request URL is: $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($change_record.sys_id)"
            }

        } while ($retryCount -lt $MaximumRetries)

        throw "Maximum retries have been reached. REST API call has failed and will not be retried."
    }

    end {
    }
}
