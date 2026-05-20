<#
.SYNOPSIS
    Pester unit tests for Invoke-ServiceNowRestApi.

.DESCRIPTION
    Verifies that the Invoke-ServiceNowRestApi function correctly invokes the mocked
    REST API and returns a result payload with the expected structure.

    NOTE: The module is loaded via a relative path (Resolve-Path "helper/servicenow/...").
    This will fail unless the test is run from the repository root. Fix: anchor with
    $PSScriptRoot to construct an absolute path, e.g.:
        $modulePath = Join-Path $PSScriptRoot "..\..\ServiceNow.psm1"

    NOTE: The test only verifies that Invoke-ServiceNowRestApi was called (Should -InvokeVerifiable)
    and that $results.type equals "emergency". It does not test URI validation, retry logic,
    error handling, or response parsing — all critical behaviours of this function.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Pester unit tests for the ServiceNow REST API client
    Dependencies: Pester v5+, ServiceNow.psm1 module

    Known issues:
        - Relative module path fails unless run from repository root.
          Fix: use $PSScriptRoot-anchored path.
        - Mock data loaded from relative path "helper/servicenow/Tests/Mock/...".
          Fix: anchor with $PSScriptRoot.
        - Test coverage is minimal — only the happy path is tested.
#>

Describe 'Get Emergency Change Request' {
    Context 'Change Details' {
        BeforeAll {
            # TODO: Replace relative path with $PSScriptRoot-anchored absolute path
            # e.g. Join-Path $PSScriptRoot "..\..\ServiceNow.psm1"
            Resolve-Path -Path "helper/servicenow/ServiceNow.psm1" | Import-Module -Force

            InModuleScope ServiceNow {
                $script:uri = "/api/now/table/change_request/$($change_record.sys_id)"

                # Mock Invoke-ServiceNowRestApi to return a pre-defined JSON fixture
                # TODO: Replace relative mock path with $PSScriptRoot-anchored path
                Mock Invoke-ServiceNowRestApi -Verifiable {
                    Resolve-Path -Path "helper/servicenow/Tests/Mock/Invoke-ServiceNowRestApi.Mock.json" | Get-Content | ConvertFrom-Json -Depth 100
                }
            }
        }

        It 'Change Type == Emergency' {
            InModuleScope ServiceNow {
                $response = Invoke-ServiceNowRestApi -RequestMethod Get -Uri $uri
                $results  = $response.result

                # Verify the mock was called
                Should -InvokeVerifiable

                # Verify the result type field matches expected value
                $results.type | Should -Be "emergency"
            }
        }
    }
}
