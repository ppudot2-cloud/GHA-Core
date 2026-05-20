<#
.SYNOPSIS
    Writes Azure DevOps formatted log messages and grouped object output to the pipeline console.

.DESCRIPTION
    This helper function is the single logging entry point for the module. It wraps the Azure
    DevOps logging command syntax (##[group], ##[endgroup], ##[debug], etc.) so that callers
    do not need to know the raw command strings. It also provides an object-dump mode that
    iterates a PSObject's non-null properties and emits each one as a debug line inside a
    collapsible group.

    Three parameter sets are supported:
        Group       — Emit a single formatted line (##[type]message). The default set.
        EndGroup    — Close the most recently opened collapsible group (##[endgroup]).
        ObjectOutput — Open a named group, emit all non-null properties as debug lines,
                       then close the group.

    Debug and warning lines are suppressed when $config.debug is $false, so verbose output
    only appears when SYSTEM_DEBUG is set in the Azure DevOps pipeline.

.PARAMETER String
    The message text to emit. Used by the Group parameter set.

.PARAMETER Type
    The Azure DevOps logging level. Valid values: group, warning, error, section, debug, command.
    Defaults to 'command'. Debug and warning output is suppressed unless $config.debug is $true.

.PARAMETER EndGroup
    Switch. When supplied, emits ##[endgroup] to close the current collapsible group.
    Belongs to the EndGroup parameter set.

.PARAMETER Object
    The PSObject whose properties will be enumerated and emitted as debug lines.
    Used by the ObjectOutput parameter set.

.PARAMETER ParsedGroupName
    The label for the collapsible group header when using ObjectOutput mode.
    Required by the ObjectOutput parameter set.

.PARAMETER ObjectOutput
    Switch. Activates object-dump mode (ObjectOutput parameter set).

.OUTPUTS
    None. All output goes to the Azure DevOps pipeline log via Write-Host.

.EXAMPLE
    Write-ConsoleOutput "Starting change request creation" -Type group

    Emits: ##[group]Starting change request creation

.EXAMPLE
    Write-ConsoleOutput -EndGroup

    Emits: ##[endgroup]

.EXAMPLE
    Write-ConsoleOutput -Object $changeRecord -ParsedGroupName "Change Record Fields" -ObjectOutput

    Opens a collapsible group named "Change Record Fields", emits each non-null property
    of $changeRecord as a ##[debug] line, then closes the group.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Centralised Azure DevOps pipeline logging helper
    Dependencies: $global:config (for the .debug flag)
#>

function Write-ConsoleOutput {
    [CmdletBinding(DefaultParameterSetName = "Group")]
    param(
        # Message to log — required for the default Group parameter set
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "Group")]
        [string] $String,

        # ADO logging level; defaults to 'command' (plain output)
        [Parameter(Mandatory = $false, Position = 1, ParameterSetName = "Group")]
        [ValidateSet("group", "warning", "error", "section", "debug", "command")]
        [string] $Type = "command",

        # Closes the current collapsible group when supplied
        [Parameter(Mandatory = $true, Position = 2, ParameterSetName = "EndGroup")]
        [switch] $EndGroup,

        # PSObject to enumerate in object-dump mode
        [Parameter(Mandatory = $true, Position = 2, ParameterSetName = "ObjectOutput")]
        [psobject] $Object,

        # Label for the collapsible group header in object-dump mode
        [Parameter(Mandatory = $true, Position = 3, ParameterSetName = "ObjectOutput")]
        [string] $ParsedGroupName,

        # Switch to activate object-dump mode
        [Parameter(Mandatory = $false, ParameterSetName = "ObjectOutput")]
        [switch] $ObjectOutput
    )

    begin {
        # Assume output should be sent unless suppressed by debug flag
        $sendOutput = $true
    }

    process {
        try {
            switch ($PSCmdlet.ParameterSetName) {
                "Group" {
                    # Build the ADO logging command string: ##[type]message
                    $output = "##[$($Type)]$($String)"
                }

                "EndGroup" {
                    # ADO command to close a collapsible group
                    $output = "##[endgroup]"
                }

                "ObjectOutput" {
                    # Build a flattened hashtable of non-null properties for readability
                    $hashtable = [ordered]@{}
                    $Object.psobject.properties.name | ForEach-Object {
                        if (-not [string]::IsNullOrWhiteSpace($Object.$PSItem)) {
                            $hashtable[$PSItem] = $Object.$PSItem
                        }
                    }

                    # Open a named collapsible group, dump each property, then close
                    Write-Host "##[group]$($ParsedGroupName)"
                    if ($hashtable.GetType().Name -eq 'OrderedDictionary') {
                        $hashtable.Keys | ForEach-Object {
                            Write-Host "##[debug]$($PSItem) : $($hashtable[$PSItem])"
                        }
                    }
                    Write-Host "##[endgroup]"
                }
            }

            # Suppress debug and warning output when not in debug mode
            if (\!($config.debug) -and ($Type -eq "warning" -or $Type -eq "debug")) {
                $sendOutput = $false
            }

            if ($sendOutput) {
                Write-Host $output
            }
        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            Write-Host $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {}
    }

    end {
    }
}
