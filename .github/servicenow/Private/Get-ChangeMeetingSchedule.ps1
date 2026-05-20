<#
.SYNOPSIS
    Returns the DateTime of the next Change Advisory Board (CAB) meeting.

.DESCRIPTION
    Calculates the date and time of the next scheduled CAB meeting, which occurs every
    Thursday at 08:50 AM. The function determines how many days from today fall on the
    next Thursday, then checks whether that meeting time has already passed today (if today
    is Thursday). If the current time is past 08:50 on a Thursday, it adds 7 days to return
    next week's meeting.

    This function is used as the anchor for all deployment window calculations in the module.
    Resolve-PlannedReleaseWindow calls this function and derives AddDays() offsets from the
    returned DateTime to schedule changes on specific days of the week.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    System.DateTime
    The DateTime of the next CAB meeting (Thursday at 08:50:00).

.EXAMPLE
    Get-ChangeMeetingSchedule
    # If today is Monday April 21 2026, returns: Thursday April 24 2026 08:50:00

.EXAMPLE
    $nextCAB = Get-ChangeMeetingSchedule
    Write-Output "Next CAB meeting is on: $nextCAB"

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Provide the anchor DateTime for CAB-relative deployment window scheduling
    Dependencies: None

.LINK
    [WalmartCICD PowerShell Module](https://dev.azure.com/walmart/DevSecOps-CICD-Framework/_git/devsecops-cicd-powershell-module)
#>

function Get-ChangeMeetingSchedule {
    [CmdletBinding()]
    param()

    begin {
    }

    process {
        try {
            # Determine this week's Thursday at 08:50 by adding the appropriate number
            # of days based on today's day-of-week integer (0=Sun through 6=Sat).
            # Friday (5) and Saturday (6) look back to the most recent Thursday, then
            # the "already passed" check below will roll forward to next week.
            switch ((Get-Date).DayOfWeek) {
                0 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(4)  }  # Sunday    -> Thu +4
                1 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(3)  }  # Monday    -> Thu +3
                2 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(2)  }  # Tuesday   -> Thu +2
                3 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(1)  }  # Wednesday -> Thu +1
                4 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0)             }  # Thursday  -> today
                5 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(-1) }  # Friday    -> Thu -1
                6 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(-2) }  # Saturday  -> Thu -2
            }

            # If the meeting time has already passed (today is Thursday afternoon, or
            # the computed date is in the past), advance to next Thursday.
            if ((Get-Date) -gt $currentWeekCAB) {
                $nextCAB = $currentWeekCAB.AddDays(7)
            }
            else {
                $nextCAB = $currentWeekCAB
            }

            return $nextCAB
        }
        catch {
            Write-Output $PSItem.ScriptStackTrace
            throw $PSItem.Exception
        }
        finally {
        }
    }

    end {
    }
}
