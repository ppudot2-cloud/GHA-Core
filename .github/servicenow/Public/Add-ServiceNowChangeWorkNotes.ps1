<#
.SYNOPSIS
    Appends a work note to the active ServiceNow Change Request.

.DESCRIPTION
    PATCHes the work_notes field on the active change request record identified by
    $change_record.sys_id. Work notes are appended (not replaced) by ServiceNow when
    the PATCH targets the work_notes field.

    This function is commonly called by Get-PipelineApprovers to log approval details
    for each deployment stage, and can be called directly to add deployment status,
    timestamps, or other contextual information to the change ticket.

.PARAMETER WorkNote
    The text to append to the change request's work notes. Supports multi-line strings.
    Example: "Stage PROD approved by: John Doe`nApproved at: 2026-04-21 14:30:00"

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    None. Side effects: one PATCH call to ServiceNow updating work_notes.

.EXAMPLE
    Add-ServiceNowChangeWorkNotes -WorkNote "Approved by John Doe at 2026-03-25 14:00"

    Appends an approval note to the active change request.

.EXAMPLE
    $note = "Stage PROD approved by: $($approver)`nApproved at: $(Get-Date)"
    Add-ServiceNowChangeWorkNotes -WorkNote $note

    Constructs a multi-line work note from pipeline variables and appends it.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Append work notes to ServiceNow Change Requests from Azure DevOps pipelines
    Dependencies: Invoke-ServiceNowRestApi, Write-ConsoleOutput,
                  $global:change_record (sys_id, number), $global:config (base_uri)

    Known issue: ($body | ConvertTo-Json -Compress -Depth 100).Replace('\n', '\n') is a no-op.
    Literal newlines in $WorkNote will be serialised by ConvertTo-Json correctly, but
    any '\n' escape sequences in the original string will not be converted to newlines.
    Use "`n" in PowerShell string literals to embed actual newline characters.
#>

function Add-ServiceNowChangeWorkNotes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkNote
    )

    begin {
        $ErrorActionPreference = "Stop"
    }

    process {
        try {
            Write-ConsoleOutput "Attempting to add the work note to the ticket"

            $uri = "/api/now/table/change_request/$($change_record.sys_id)"

            # Build a minimal patch body — ServiceNow appends work_notes rather than replacing them
            $body = @{
                'work_notes' = $WorkNote
            }

            # NOTE: .Replace('\n', '\n') is a no-op — see Known Issues
            $json = ($body | ConvertTo-Json -Compress -Depth 100).Replace('\n', '\n')

            $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Patch -Body $json
            $results  = $response.result

            Write-ConsoleOutput "Added work note to $($change_record.number) with sys id $($change_record.sys_id)." -Type section

            # Collect non-null fields from the PATCH response for display
            $output = [ordered]@{}
            foreach ($property in $results.psobject.properties.name) {
                if (\![string]::IsNullOrWhiteSpace($results.$property)) {
                    $output[$property] = $results.$property
                }
            }

            Write-ConsoleOutput "===== Add Change Request Work Notes Begin ====="
            $output | Format-Table
            Write-ConsoleOutput "===== Add Change Request Work Notes End ====="
        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            Write-Host $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            Write-ConsoleOutput "The ServiceNow Change Request URL is: $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($change_record.sys_id)"
        }
    }

    end {
    }
}
