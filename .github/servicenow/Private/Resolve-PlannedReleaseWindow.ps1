<#
.SYNOPSIS
    Computes the Start/End DateTime pair for the next deployment window anchored on the
    next Change Advisory Board (CAB) meeting.

.DESCRIPTION
    Given a target weekday and an optional change-risk level, returns a hashtable with
    Start and End keys describing the exact deployment window to schedule in ServiceNow.
    This is the single source of truth for release-window date math in the module.

    End-to-end behaviour:

        1. begin block. Calls Get-ChangeMeetingSchedule to get $nextCAB (next Thursday 08:50).
           Sets $managedChangeWindow = $true when RiskLevel is Moderate or High, which
           selects the early-morning window for weekday deployments.

        2. process block. A switch on $DesiredDayOfWeek runs one of six branches:
               a) Calls Set-ChangeWindow -MorningWindow <bool> to get window start time and span.
               b) Computes $start by splicing the time-of-day onto the CAB+N date.
               c) Computes $end by adding .Span hours to $start.
               d) Returns a hashtable: @{ Start = $start; End = $end }

           AddDays offsets from next CAB (Thursday):
               Saturday  -> +2    Sunday -> +3    Monday  -> +4
               Tuesday   -> +5    Wednesday -> +6  Thursday -> +7

           Friday is excluded from ValidateSet — it is a deployment blackout day.
           Saturday and Sunday always use the non-morning (evening) window regardless of risk.
           Weekday Mon-Thu use morning window for Moderate/High, evening for Low.

        3. catch block. Logs stack trace and rethrows the .NET exception object unchanged.

    NOTE: This function currently calls Switch-ChangeWindow which does not exist.
          The correct function name is Set-ChangeWindow (defined in New-StartDateEstimate.ps1).
          This is a CRITICAL bug — all window calculations will fail at runtime until fixed.

.PARAMETER DesiredDayOfWeek
    Target weekday for the deployment window. One of: Sunday, Monday, Tuesday, Wednesday,
    Thursday, Saturday. Friday is excluded (deployment blackout day).

.PARAMETER RiskLevel
    Change risk tier. One of: Low, Moderate, High. Defaults to 'High'.
    Moderate and High risk changes use the morning window (04:00, 3h) for weekday deployments.
    Low risk uses the evening window (23:00, 8h). Weekend deployments always use the evening window.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.Collections.Hashtable
    A hashtable with two keys:
        Start — deployment window start as 'yyyy-MM-dd HH:mm:ss'
        End   — deployment window end   as 'yyyy-MM-dd HH:mm:ss'

.EXAMPLE
    Resolve-PlannedReleaseWindow -DesiredDayOfWeek 'Tuesday'

    Returns the Start/End for next Tuesday using the managed morning window
    (RiskLevel defaults to High).

.EXAMPLE
    $win = Resolve-PlannedReleaseWindow -DesiredDayOfWeek 'Monday' -RiskLevel 'Low'
    $win.Start   # e.g. "2026-04-27 23:00:00"
    $win.End     # e.g. "2026-04-28 07:00:00"

    A low-risk Monday deployment — uses the evening window.

.EXAMPLE
    $win = Resolve-PlannedReleaseWindow -DesiredDayOfWeek 'Saturday'
    # Saturday always uses the evening window regardless of risk level.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Single source of truth for deployment window date calculations
    Dependencies: Get-ChangeMeetingSchedule, Set-ChangeWindow (NOTE: currently calls
                  Switch-ChangeWindow which does not exist — must be renamed to Set-ChangeWindow)

    Known issues:
        - All six switch branches call Switch-ChangeWindow instead of Set-ChangeWindow.
          This is a critical bug that must be resolved before the function can execute.
        - The finally block is empty; consider logging the computed window for debugging.
#>
function Resolve-PlannedReleaseWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Saturday")]
        [string] $DesiredDayOfWeek,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Low", "Moderate", "High")]
        [string] $RiskLevel = "High"
    )

    begin {
        # Anchor: next Thursday CAB meeting DateTime
        $nextCAB = Get-ChangeMeetingSchedule

        # Determine if this change needs a managed (morning) window
        $managedChangeWindow = $false
        if ($RiskLevel -eq 'Moderate' -or $RiskLevel -eq 'High') {
            $managedChangeWindow = $true
        }
    }

    process {
        try {
            switch ($DesiredDayOfWeek) {
                "Sunday" {
                    # Sunday always uses evening window — no managed window override
                    # BUG: Switch-ChangeWindow should be Set-ChangeWindow
                    $window = Switch-ChangeWindow -MorningWindow $false
                    $start  = (Get-Date -Date (Get-Date $nextCAB.AddDays(3) -Format yyyy-MM-ddT"$($window.Start)")).ToString("yyyy-MM-dd HH:mm:ss")
                    $end    = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $end }
                }
                "Monday" {
                    # Managed changes (Mod/High) get morning window; Low gets evening
                    if ($managedChangeWindow) { $window = Switch-ChangeWindow -MorningWindow $true }
                    else                      { $window = Switch-ChangeWindow -MorningWindow $false }
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(4) -Format yyyy-MM-ddT"$($window.Start)")).ToString("yyyy-MM-dd HH:mm:ss")
                    $end   = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $end }
                }
                "Tuesday" {
                    if ($managedChangeWindow) { $window = Switch-ChangeWindow -MorningWindow $true }
                    else                      { $window = Switch-ChangeWindow -MorningWindow $false }
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(5) -Format yyyy-MM-ddT"$($window.Start)")).ToString("yyyy-MM-dd HH:mm:ss")
                    $end   = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $end }
                }
                "Wednesday" {
                    if ($managedChangeWindow) { $window = Switch-ChangeWindow -MorningWindow $true }
                    else                      { $window = Switch-ChangeWindow -MorningWindow $false }
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(6) -Format yyyy-MM-ddT"$($window.Start)")).ToString("yyyy-MM-dd HH:mm:ss")
                    $end   = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $end }
                }
                "Thursday" {
                    if ($managedChangeWindow) { $window = Switch-ChangeWindow -MorningWindow $true }
                    else                      { $window = Switch-ChangeWindow -MorningWindow $false }
                    # Next Thursday = CAB + 7 days (following week)
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(7) -Format yyyy-MM-ddT"$($window.Start)")).ToString("yyyy-MM-dd HH:mm:ss")
                    $end   = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $end }
                }
                "Saturday" {
                    # Saturday always uses evening window
                    $window = Switch-ChangeWindow -MorningWindow $false
                    $start  = (Get-Date -Date (Get-Date $nextCAB.AddDays(2) -Format yyyy-MM-ddT"$($window.Start)")).ToString("yyyy-MM-dd HH:mm:ss")
                    $end    = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $end }
                }
            }

            return $deploymentWindow
        }
        catch {
            Write-Output $PSItem.ScriptStackTrace
            throw $PSItem.Exception
        }
        finally {
            # Consider adding: Write-ConsoleOutput "Computed window: Start=$($deploymentWindow.Start), End=$($deploymentWindow.End)" -Type debug
        }
    }

    end {
    }
}
