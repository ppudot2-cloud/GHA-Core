<#
.SYNOPSIS
    Updates the planned start and end dates (change window) on the active ServiceNow
    Change Request.

.DESCRIPTION
    Calculates the appropriate deployment window using Resolve-PlannedReleaseWindow, then
    PATCHes the start_date and end_date fields on the active change request record via the
    ServiceNow REST API.

    For Low risk changes or when running against the production ServiceNow instance, the
    function overrides the calculated window with an immediate 3-hour window starting now.
    This allows Low risk changes to be scheduled without waiting for the next CAB cycle.

    NOTE: The production instance check is inverted. The condition checks whether
    $config.base_uri equals "https://walmart.service-now.com" (the production URL) and
    applies the immediate window if so. The intent was almost certainly to apply the
    immediate window for the DEV/test instance, not for production. In production this means
    every change (regardless of risk) gets an immediate 3-hour window rather than the
    CAB-calculated window.

.PARAMETER DesiredDayOfWeek
    The target weekday for the deployment window. Passed to Resolve-PlannedReleaseWindow.
    One of: Sunday, Monday, Tuesday, Wednesday, Thursday, Saturday.

.PARAMETER RiskLevel
    The risk level of the change. One of: Low, Moderate, High.
    Low risk changes always receive an immediate 3-hour window regardless of the
    calculated CAB window.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject
    The .result payload from ServiceNow after updating the change window fields.

.EXAMPLE
    Set-ServiceNowChangeWindow -DesiredDayOfWeek "Thursday" -RiskLevel "Moderate"

    Calculates the next Thursday morning window and sets it on the active change request.

.EXAMPLE
    Set-ServiceNowChangeWindow -DesiredDayOfWeek "Sunday" -RiskLevel "Low"

    Low risk override: sets an immediate 3-hour window starting now, regardless of the
    Sunday calculation.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Automate Change Window scheduling in ServiceNow
    Dependencies: Resolve-PlannedReleaseWindow, Write-ConsoleOutput, Invoke-ServiceNowRestApi,
                  $global:change_record (number, sys_id), $global:config (base_uri)

    Known issues:
        - The production URL check ($config.base_uri -eq "https://walmart.service-now.com")
          applies the immediate window to production rather than dev/test. The condition
          should check for the DEV instance URL, not the production URL.
        - The finally block references $results.number for logging, but if the PATCH failed,
          $results may be null, causing a null-dereference error in the finally block.
#>

function Set-ServiceNowChangeWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DesiredDayOfWeek,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Low", "Moderate", "High")]
        [string] $RiskLevel
    )

    begin {
        # Calculate the CAB-anchored deployment window for the target day and risk level
        $timespan = Resolve-PlannedReleaseWindow -DesiredDayOfWeek $DesiredDayOfWeek `
                                                 -RiskLevel $RiskLevel

        # NOTE: This condition is inverted — the immediate window is applied to production.
        # It should check for the DEV instance URL instead.
        if (($config.base_uri -eq "https://walmart.service-now.com") -or ($RiskLevel -eq 'Low')) {
            # Override with an immediate 3-hour window starting now
            $timespan = @{
                Start = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                End   = (Get-Date).AddHours(3).ToString('yyyy-MM-dd HH:mm:ss')
            }
        }
    }

    process {
        try {
            Write-ConsoleOutput "Set Change Window: $($change_record.number)" -Type group

            $uri = "/api/now/table/change_request/$($change_record.sys_id)"

            # Build the PATCH body with only the start and end date fields
            $body = [ordered]@{
                "start_date" = $timespan.Start
                "end_date"   = $timespan.End
            }

            $json = $body | ConvertTo-Json -Compress -Depth 100

            Write-ConsoleOutput "Attempting to update the ServiceNow Change planned start $($timespan.Start) and end $($timespan.End) dates."

            $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Patch -Body $json

            if ($env:SYSTEM_DEBUG) {
                # Verbose logging — only visible when SYSTEM_DEBUG is set
                Write-ConsoleOutput "Verbose logging is enabled. Full REST API response message is: "
                $response
                Write-ConsoleOutput "Verbose logging is enabled. Content REST API response message is: "
                $response.result
            }

            $results = $response.result

            # Collect all non-null fields from the response for display
            $output = [ordered]@{}
            foreach ($property in $results.psobject.properties.name) {
                if (\![string]::IsNullOrWhiteSpace($results.$property)) {
                    $output[$property] = $results.$property
                }
            }
        }
        catch {
            Write-Output $PSItem.ScriptStackTrace
            Write-Output $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            # NOTE: $results.number / $results.sys_id may be null if the PATCH failed
            Write-ConsoleOutput "Created ServiceNow Change request: $($results.number)"
            Write-ConsoleOutput "$($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($results.sys_id)"
            Write-ConsoleOutput "Change request number is $($results.number) and record id $($results.sys_id) with calculated risk level: $($results.risk)"
        }
    }

    end {
        Write-ConsoleOutput "Update Change Requests Results" -Type section
        $output | Format-Table
        return $results
    }
}
