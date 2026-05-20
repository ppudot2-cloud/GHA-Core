<#
.SYNOPSIS
    Retrieves the approval status of the active ServiceNow Change Request and sets an
    Azure DevOps pipeline variable indicating whether deployment may proceed.

.DESCRIPTION
    GETs the active change request from ServiceNow and inspects its approval field.
    Based on the result, it emits the CHANGE_IS_APPROVED pipeline variable and either
    allows the pipeline to continue or marks the task as failed.

    Three outcomes are handled:
        1. Approval status cannot be retrieved — sets CHANGE_IS_APPROVED=false and throws
           a terminating error to fail the pipeline step.
        2. approval == 'approved' — sets CHANGE_IS_APPROVED=true and returns, allowing
           downstream steps to proceed.
        3. Any other value (e.g. 'requested', 'rejected') — sets CHANGE_IS_APPROVED=false,
           logs a pipeline error with the change request URL, and emits
           ##vso[task.complete result=FailedWithIssues] to mark the task without killing
           the entire pipeline run.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    None (to console). Sets Azure DevOps pipeline variables:
        CHANGE_IS_APPROVED — 'true' if approved, 'false' otherwise (isOutput=true)

.EXAMPLE
    Get-ServiceNowApprovalStatus

    Checks approval and sets CHANGE_IS_APPROVED. If not approved, marks the task as
    FailedWithIssues so the pipeline can be re-run once the change is approved.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Gate pipeline deployments on ServiceNow change approval status
    Dependencies: Invoke-ServiceNowRestApi, Write-ConsoleOutput,
                  $global:change_record (sys_id, number), $global:config (base_uri)

    Note: ##vso[task.complete result=FailedWithIssues] marks the task as failed-with-issues
    but does not cause dependent jobs to be skipped by default. Use this function in a gate
    step whose failure condition is checked by subsequent pipeline logic.
#>

function Get-ServiceNowApprovalStatus {
    [CmdletBinding()]
    param()

    begin {
        $ErrorActionPreference = "Stop"
    }

    process {
        try {
            Write-ConsoleOutput "Attempting to get the approval status for change number $($change_record.number) with sys id $($change_record.sys_id)."

            $uri = "/api/now/table/change_request/$($change_record.sys_id)"

            # Fetch the change request and extract the approval field value
            $response      = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Get
            $approvalStatus = $response.result | Select-Object -ExpandProperty approval

            Write-ConsoleOutput "Approval status: $($approvalStatus)" -Type section

            if (-not $approvalStatus) {
                # Could not retrieve approval status — emit false and terminate
                Write-ConsoleOutput "Failed to retrieve approval status for change ticket number $($change_record.number)." -Type error
                Write-Output "##vso[task.setvariable variable=CHANGE_IS_APPROVED;isOutput=true]false"
                throw "Failed to retrieve approval status for change ticket number $($change_record.number)."
            }
            elseif ($approvalStatus -eq 'approved') {
                # Change is approved — allow deployment to proceed
                Write-Output "##vso[task.setvariable variable=CHANGE_IS_APPROVED;isOutput=true]true"
                Write-ConsoleOutput "The ServiceNow Change Request $($change_record.number) is approved. Proceed with the deployment."
                return
            }
            else {
                # Change is not yet approved — block deployment but allow pipeline to continue
                # so that re-running this stage will re-check once approval is granted
                Write-Output "##vso[task.setvariable variable=CHANGE_IS_APPROVED;isOutput=true]false"
                Write-Output "##vso[task.logissue type=error]The ServiceNow Change Request $($change_record.number) is not approved. Re-run the Pre-Deployment stage to retry checking approval status. Change record URL: $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($change_record.sys_id)"
                Write-Output "##vso[task.complete result=FailedWithIssues;]"
                return
            }
        }
        catch {
            Write-Output $PSItem.ScriptStackTrace
            Write-Output $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            Write-ConsoleOutput "The ServiceNow Change Request URL is: $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($change_record.sys_id)"
        }
    }

    end {
    }
}
