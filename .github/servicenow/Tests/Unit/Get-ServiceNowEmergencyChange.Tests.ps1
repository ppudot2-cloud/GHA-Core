<#
.SYNOPSIS
    Pester unit tests for Get-ServiceNowEmergencyChange.

.DESCRIPTION
    Verifies that Get-ServiceNowEmergencyChange correctly validates the type and state
    of an emergency change request using a mocked Invoke-ServiceNowRestApi response.

    Tests:
        1. The function returns a result with type == "emergency".
        2. The function returns a result with state == "-1" (Implement).

    NOTE: The module is loaded via a hardcoded absolute path:
        /home/chpresley/git/azuredevops/azure-pipeline-yaml-templates/...
    This will fail on any machine other than the original developer's. Fix: use
    $PSScriptRoot to construct an environment-independent path.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Pester unit tests for emergency change validation
    Dependencies: Pester v5+, ServiceNow.psm1 module

    Known issues:
        - Hardcoded absolute path /home/chpresley/... must be replaced with
          a $PSScriptRoot-anchored relative path before this test can run in CI.
        - Tests do not cover the negative cases: non-emergency type or wrong state.
        - No test for when Invoke-ServiceNowRestApi throws an exception.
#>

Describe 'Get Emergency Change Request' {
    Context 'Change Details' {
        BeforeAll {
            # TODO: Replace hardcoded path with $PSScriptRoot-anchored path, e.g.:
            # $modulePath = Join-Path $PSScriptRoot "..\..\ServiceNow.psm1"
            # Import-Module $modulePath -Force
            Resolve-Path -Path "/home/chpresley/git/azuredevops/azure-pipeline-yaml-templates/helper/servicenow/ServiceNow.psm1" | Import-Module -Force

            InModuleScope ServiceNow {
                $script:EmergencyChangeId = "CHG0040007"

                # Mock with inline response object — type=emergency, state=-1 (Implement)
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
                $results = Get-ServiceNowEmergencyChange -EmergencyChangeId $EmergencyChangeId
                Should -InvokeVerifiable
                $results.type | Should -Be "emergency"
            }
        }

        It 'Change State == Implement' {
            InModuleScope ServiceNow {
                $results = Get-ServiceNowEmergencyChange -EmergencyChangeId $EmergencyChangeId
                Should -InvokeVerifiable
                $results.state | Should -Be "-1"
            }
        }
    }
}
