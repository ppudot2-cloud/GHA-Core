<#
.SYNOPSIS
    Pester unit tests for Get-ServiceNowChangeRequest.

.DESCRIPTION
    Verifies that Get-ServiceNowChangeRequest returns the expected change record fields
    using a mocked Invoke-ServiceNowRestApi response.

    Tests:
        1. The function returns a result with type == "emergency".
        2. The function returns a result with state == "-1" (Implement).

    NOTE: The function is called with -EmergencyChangeId which is not a declared parameter
    of Get-ServiceNowChangeRequest. This will cause a parameter binding error at runtime.
    The function does not accept any mandatory parameters — the change number is read from
    $change_record.number (a global). Either the test should not pass -EmergencyChangeId,
    or the function needs a -ChangeTicketNumber parameter added.

    NOTE: The module path is a relative path anchored to the repository root (not $PSScriptRoot),
    so the test will fail unless run from the correct working directory.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Pester unit tests for ServiceNow change request retrieval
    Dependencies: Pester v5+, ServiceNow.psm1 module

    Known issues:
        - Get-ServiceNowChangeRequest does not have an -EmergencyChangeId parameter.
          The test call will fail with "A parameter cannot be found that matches parameter
          name 'EmergencyChangeId'". Fix: remove the parameter from the call, or add the
          parameter to the function.
        - Relative module path fails unless run from the repository root.
          Fix: use Join-Path $PSScriptRoot to build an absolute path.
        - Tests only cover the happy path; no negative case testing.
#>

$PesterPreference = [PesterConfiguration]::Default
$PesterPreference.Debug.ShowFullErrors = $true

Describe 'Get Change Request Details' {
    Context 'Change Details' {
        BeforeAll {
            # TODO: Replace relative path with $PSScriptRoot-anchored path
            Resolve-Path -Path "helper/servicenow/ServiceNow.psm1" | Import-Module -Force

            # $EmergencyChangeId is set here but Get-ServiceNowChangeRequest does not
            # accept this as a parameter — it uses $change_record.number from module scope
            $EmergencyChangeId = "CHG0040007"
        }

        BeforeEach {
            InModuleScope ServiceNow {
                [string]$script:uri = "/api/sn_chg_rest/change/{0}" -f $change_record.sys_id

                # Mock returns a minimal change record with emergency type and Implement state
                Mock Invoke-ServiceNowRestApi -Verifiable {
                    @{
                        result = @{
                            type  = "emergency"
                            state = "-1"
                        }
                    }
                }
            }
        }

        It 'Change Type == Emergency' {
            InModuleScope ServiceNow {
                # NOTE: -EmergencyChangeId is not a valid parameter of Get-ServiceNowChangeRequest
                # This call will fail with a parameter binding error at runtime
                $results = Get-ServiceNowChangeRequest -EmergencyChangeId $EmergencyChangeId
                Should -InvokeVerifiable
                $results.type | Should -Be "emergency"
            }
        }

        It 'Change State == Implement' {
            InModuleScope ServiceNow {
                # NOTE: Same parameter binding error as above
                $results = Get-ServiceNowChangeRequest -EmergencyChangeId $EmergencyChangeId
                Should -InvokeVerifiable
                $results.state | Should -Be "-1"
            }
        }
    }
}
