# Combined ServiceNow CAB Helper Functions
# These four functions work together to calculate deployment windows anchored
# on the next Change Advisory Board (CAB) meeting (every Thursday at 08:50).

# ==================== Get-NumericDayOfWeek ====================
<#
.SYNOPSIS
    Converts a day-of-week name to its numeric equivalent (0 = Sunday, 6 = Saturday).

.DESCRIPTION
    Returns an integer from 0 (Sunday) through 6 (Saturday) for the supplied day name.
    Used internally by Get-NextScheduledCAB to determine how many days to add to reach
    the next Thursday CAB meeting.

.PARAMETER DayOfWeek
    The name of the day. Must be one of: Sunday, Monday, Tuesday, Wednesday, Thursday,
    Friday, Saturday.

.INPUTS
    None. Does not accept pipeline input.

.OUTPUTS
    System.Int32
    Integer representation of the day: 0 (Sunday) to 6 (Saturday).

.EXAMPLE
    Get-NumericDayOfWeek -DayOfWeek "Thursday"
    # Returns: 4

.EXAMPLE
    Get-NumericDayOfWeek -DayOfWeek "Monday"
    # Returns: 1

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Day-of-week integer lookup used by CAB scheduling functions
#>
function Get-NumericDayOfWeek {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")]
        [string] $DayOfWeek
    )

    process {
        try {
            # Map each day name to its .NET DayOfWeek integer equivalent
            switch ($DayOfWeek) {
                "Sunday"    { $numericDayOfWeek = 0 }
                "Monday"    { $numericDayOfWeek = 1 }
                "Tuesday"   { $numericDayOfWeek = 2 }
                "Wednesday" { $numericDayOfWeek = 3 }
                "Thursday"  { $numericDayOfWeek = 4 }
                "Friday"    { $numericDayOfWeek = 5 }
                "Saturday"  { $numericDayOfWeek = 6 }
            }
            return $numericDayOfWeek
        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            throw $PSItem.Exception
        }
        finally {}
    }
    end {}
}

# ==================== Get-NextScheduledCAB ====================
<#
.SYNOPSIS
    Returns the DateTime of the next weekly Change Advisory Board (CAB) meeting.

.DESCRIPTION
    Calculates when the next Thursday-at-08:50 CAB meeting falls, accounting for whether
    the current day/time is before or after this week's meeting. If the current moment
    is past this week's Thursday 08:50, it advances by 7 days to the following week.

    This function is the anchor for all deployment window calculations in the module.
    Resolve-PlannedReleaseWindow uses the returned DateTime to compute AddDays() offsets
    for each target weekday.

.INPUTS
    None. Does not accept pipeline input.

.OUTPUTS
    System.DateTime
    The DateTime of the next CAB meeting (Thursday at 08:50:00).

.EXAMPLE
    $cab = Get-NextScheduledCAB
    # If today is Tuesday April 22 2026, returns Thursday April 24 2026 08:50:00

.EXAMPLE
    $cab = Get-NextScheduledCAB
    Write-Output "Next CAB: $cab"

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Anchor DateTime for deployment window calculations
    Dependencies: Get-NumericDayOfWeek
#>
function Get-NextScheduledCAB {
    [CmdletBinding()]
    param()

    begin {}

    process {
        try {
            # Calculate this week's Thursday at 08:50, offset from today's numeric day.
            # DayOfWeek values: 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat
            # Thursday is day 4, so AddDays(4 - currentDay) lands on Thursday.
            switch (Get-NumericDayOfWeek -DayOfWeek (Get-Date).DayOfWeek) {
                0 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(4)  }  # Sunday: +4
                1 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(3)  }  # Monday: +3
                2 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(2)  }  # Tuesday: +2
                3 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(1)  }  # Wednesday: +1
                4 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0)             }  # Thursday: today
                5 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(-1) }  # Friday: look back
                6 { $currentWeekCAB = (Get-Date -Hour 8 -Minute 50 -Second 0).AddDays(-2) }  # Saturday: look back
            }

            # If this week's CAB has already passed, roll forward to next Thursday
            if ((Get-Date) -gt $currentWeekCAB) {
                $nextCAB = $currentWeekCAB.AddDays(7)
            }
            else {
                $nextCAB = $currentWeekCAB
            }

            return $nextCAB
        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            throw $PSItem.Exception
        }
        finally {}
    }
    end {}
}

# ==================== Set-ChangeWindow ====================
<#
.SYNOPSIS
    Returns the start time-of-day and duration (in hours) for either the morning or evening
    deployment window.

.DESCRIPTION
    Encapsulates the two permitted deployment windows:
        Morning window — 04:00, 3-hour span. Used for Moderate/High risk weekday deployments.
        Evening window — 23:00, 8-hour span. Used for Low risk changes and weekend deployments.

    Returns a hashtable with keys:
        Start — time-of-day string formatted for use in date composition (HH:mm)
        Span  — integer number of hours the window covers

    Callers use the returned .Start to splice a time onto a date string, then .Span to
    calculate the end time via AddHours().

.PARAMETER MorningWindow
    When $true, returns the morning (04:00, 3h) window.
    When $false, returns the evening (23:00, 8h) window.

.INPUTS
    None. Does not accept pipeline input.

.OUTPUTS
    System.Collections.Hashtable
    Hashtable with keys: Start (string, time-of-day), Span (int, hours).

.EXAMPLE
    $w = Set-ChangeWindow -MorningWindow $true
    # Returns: @{ Start = "04:00"; Span = 3 }

.EXAMPLE
    $w = Set-ChangeWindow -MorningWindow $false
    # Returns: @{ Start = "23:00"; Span = 8 }

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Return deployment window start time and duration based on risk tier
#>
function Set-ChangeWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [boolean] $MorningWindow
    )

    begin {
        # Window constants — adjust here if org policy changes
        $morningWindowStart = 04   # 4:00 AM
        $morningWindowSpan  = 3    # 3-hour window
        $eveningWindowStart = 23   # 11:00 PM
        $eveningWindowSpan  = 8    # 8-hour window (crosses midnight)
    }

    process {
        try {
            if ($MorningWindow) {
                # High/Moderate risk: smaller early-morning window
                $timespan = @{
                    "Start" = Get-Date -Hour $morningWindowStart -Minute 00 -Second 00 -UFormat %R
                    "Span"  = $morningWindowSpan
                }
            }
            else {
                # Low risk / weekends: longer evening/overnight window
                $timespan = @{
                    "Start" = Get-Date -Hour $eveningWindowStart -Minute 00 -Second 00 -UFormat %R
                    "Span"  = $eveningWindowSpan
                }
            }
            return $timespan
        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            throw $PSItem.Exception
        }
        finally {}
    }
    end {}
}

# ==================== New-StartDateEstimate ====================
<#
.SYNOPSIS
    Returns the deployment window (Start/End DateTime strings) for a given target weekday,
    anchored on the next CAB meeting.

.DESCRIPTION
    Combines Get-NextScheduledCAB and Set-ChangeWindow to compute the concrete Start and End
    datetime strings for a deployment scheduled on the desired day of the week.

    The AddDays() offsets from the next CAB (Thursday) to each weekday are:
        Saturday  -> CAB + 2 days
        Sunday    -> CAB + 3 days
        Monday    -> CAB + 4 days
        Tuesday   -> CAB + 5 days
        Wednesday -> CAB + 6 days
        Thursday  -> CAB + 7 days (following week's Thursday)

    Friday is excluded because it is a deployment blackout day.

    Risk-level window selection:
        Low risk         -> Evening window (23:00, 8h) for all weekdays
        Moderate/High    -> Morning window (04:00, 3h) for Mon-Thu
        Saturday/Sunday  -> Always evening window regardless of risk

.PARAMETER DesiredDayOfWeek
    Target weekday. One of: Sunday, Monday, Tuesday, Wednesday, Thursday, Saturday.
    Friday is not accepted (deployment blackout day).

.PARAMETER RiskLevel
    Change risk tier. One of: Low, Moderate, High. Defaults to 'High'.
    Determines whether the morning or evening window is used for weekday deployments.

.INPUTS
    None. Does not accept pipeline input.

.OUTPUTS
    System.Collections.Hashtable
    Hashtable with keys:
        Start — deployment window start as 'yyyy-MM-dd HH:mm:ss'
        End   — deployment window end as 'yyyy-MM-dd HH:mm:ss'

.EXAMPLE
    New-StartDateEstimate -DesiredDayOfWeek "Tuesday" -RiskLevel "High"
    # Returns window starting Tuesday at 04:00, ending at 07:00

.EXAMPLE
    $win = New-StartDateEstimate -DesiredDayOfWeek "Saturday"
    # Returns window starting Saturday at 23:00, ending Sunday at 07:00

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Calculate concrete deployment window datetimes for ServiceNow CR scheduling
    Dependencies: Get-NextScheduledCAB, Set-ChangeWindow
#>
function New-StartDateEstimate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")]
        [string] $DesiredDayOfWeek,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Low", "Moderate", "High")]
        [string] $RiskLevel = "High"
    )

    begin {
        # Get the anchor DateTime (next Thursday CAB meeting)
        $nextCAB = Get-NextScheduledCAB

        # Determine if this change requires a managed (morning) deployment window
        $managedChangeWindow = $false
        if ($RiskLevel -eq "Moderate" -or $RiskLevel -eq "High") {
            $managedChangeWindow = $true
        }
    }

    process {
        try {
            switch ($DesiredDayOfWeek) {
                "Sunday" {
                    # Weekend: always evening window regardless of risk
                    if ($managedChangeWindow) { $window = Set-ChangeWindow -MorningWindow $true }
                    else { $window = Set-ChangeWindow -MorningWindow $false }
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(3) -Format yyyy-MM-ddT$($window.Start))).ToString("yyyy-MM-dd HH:mm:ss")
                    $send  = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $send }
                }
                "Monday" {
                    if ($managedChangeWindow) { $window = Set-ChangeWindow -MorningWindow $true }
                    else { $window = Set-ChangeWindow -MorningWindow $false }
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(4) -Format yyyy-MM-ddT$($window.Start))).ToString("yyyy-MM-dd HH:mm:ss")
                    $send  = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $send }
                }
                "Tuesday" {
                    if ($managedChangeWindow) { $window = Set-ChangeWindow -MorningWindow $true }
                    else { $window = Set-ChangeWindow -MorningWindow $false }
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(5) -Format yyyy-MM-ddT$($window.Start))).ToString("yyyy-MM-dd HH:mm:ss")
                    $send  = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $send }
                }
                "Wednesday" {
                    if ($managedChangeWindow) { $window = Set-ChangeWindow -MorningWindow $true }
                    else { $window = Set-ChangeWindow -MorningWindow $false }
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(6) -Format yyyy-MM-ddT$($window.Start))).ToString("yyyy-MM-dd HH:mm:ss")
                    $send  = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $send }
                }
                "Thursday" {
                    if ($managedChangeWindow) { $window = Set-ChangeWindow -MorningWindow $true }
                    else { $window = Set-ChangeWindow -MorningWindow $false }
                    # Thursday = next week's Thursday (CAB + 7)
                    $start = (Get-Date -Date (Get-Date $nextCAB.AddDays(7) -Format yyyy-MM-ddT$($window.Start))).ToString("yyyy-MM-dd HH:mm:ss")
                    $send  = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $send }
                }
                "Saturday" {
                    # Weekend: always evening window
                    $window = Set-ChangeWindow -MorningWindow $false
                    $start  = (Get-Date -Date (Get-Date $nextCAB.AddDays(2) -Format yyyy-MM-ddT$($window.Start))).ToString("yyyy-MM-dd HH:mm:ss")
                    $send   = ((Get-Date -Date $start).AddHours($window.Span)).ToString("yyyy-MM-dd HH:mm:ss")
                    $deploymentWindow = @{ "Start" = $start; "End" = $send }
                }
            }

            return $deploymentWindow
        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            throw $PSItem.Exception
        }
        finally {}
    }
    end {}
}
