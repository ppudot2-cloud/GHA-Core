<#
.SYNOPSIS
    Determines the overall status of a Production deployment by analyzing Azure DevOps pipeline stages and tasks.

.DESCRIPTION
    This function evaluates the status of various stages and tasks in a production deployment pipeline.
    It checks for successful completion, issues, failures, cancellations, and in-progress states.
    
    It sets an Azure DevOps pipeline variable 'PRODUCTION_STAGE_STATUS' with the final result.

.PARAMETER MaximumRetries
    Maximum number of retry attempts if API calls fail. Default is 5.

.PARAMETER RetryDelay
    Delay in milliseconds between retries. Default is 3000 (3 seconds).

.OUTPUTS
    Sets pipeline variable: PRODUCTION_STAGE_STATUS

.EXAMPLE
    Get-ProductionDeploymentStatus

.EXAMPLE
    Get-ProductionDeploymentStatus -MaximumRetries 10 -RetryDelay 5000

#>

function Get-ProductionDeploymentStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int] $MaximumRetries = 5,

        [Parameter(Mandatory = $false)]
        [int] $RetryDelay = 3000
    )

    begin {
        $successCodes = "succeeded", "succeededWithIssues", "skipped"

        $timeline = @{}
        $isDynamicsDeployment = $false
        $dynamicsSolutionImported = $false
        $dynamicsCustomizationsPassing = $false
        $dynamicsWorkFlowsPassing = $false
        $dynamicsTestsPassing = $false
        $dynamicsSolutionDeployed = $false

        $stages = @{}
        $stagesSucceeded = @{}
        $stagesSucceededWithIssues = @{}
        $stagesFailed = @{}
        $stagesCanceled = @{}
        $stagesSkipped = @{}
        $stagesInProgress = @{}
        $stagesPending = @{}
    }

    process {
        try {
            $timeline = Get-PipelineTimeline

            foreach ($object in $timeline) {
                # Capture Dynamics / Power Platform tasks
                if ($object.task.name -eq 'PowerPlatformImportSolution') {
                    $key = $object.id
                    $dynamicsTasks[$key] = $object
                    if ($object.result -eq 'succeeded') {
                        $dynamicsSolutionImported = $true
                    }
                }

                if ($object.task.name -eq 'PowerPlatformPublishCustomizations') {
                    $key = $object.id
                    $dynamicsTasks[$key] = $object
                    if ($object.result -in $successCodes) {
                        $dynamicsCustomizationsPassing = $true
                    }
                }

                if ($object.name -eq 'Activate Flows') {
                    $key = $object.id
                    $dynamicsTasks[$key] = $object
                    if ($object.result -in $successCodes) {
                        $dynamicsWorkFlowsPassing = $true
                    }
                }

                if ($object.task.name -eq 'VSTest') {
                    $key = $object.id
                    $dynamicsTasks[$key] = $object
                    if ($object.result -in $successCodes) {
                        $dynamicsTestsPassing = $true
                    }
                }
            }

            # Determine if this is a Dynamics deployment
            if ($dynamicsTasks.Count -gt 0) {
                $isDynamicsDeployment = $true
                if ($dynamicsSolutionImported -and 
                    $dynamicsCustomizationsPassing -and 
                    $dynamicsWorkFlowsPassing -and 
                    $dynamicsTestsPassing) {
                    $dynamicsSolutionDeployed = $true
                }
            }

            if ($isDynamicsDeployment) {
                if ($dynamicsSolutionDeployed) {
                    $result = "Successful"
                }
                else {
                    $result = "Unsuccessful"
                }
            }
            else {
                # Standard stage-based evaluation
                foreach ($object in $timeline) {
                    if (($object.type -eq 'Stage') -and 
                        ($object.identifier -notlike '*ChangeRequest*') -and 
                        ($object.identifier -like '*PROD*')) {
                        
                        Write-ConsoleOutput $object -ParsedGroupName "Stage $($object.identifier) ($($object.id)) object" -ObjectOutput
                        $stages[$object.id] = $object
                    }
                }

                foreach ($key in $stages.Keys) {
                    Write-ConsoleOutput "Stage '$($stages[$key].identifier)' returned state '$($stages[$key].state)' with the result '$($stages[$key].result)'" -Type debug

                    if ($stages[$key].state -eq 'completed') {
                        switch ($stages[$key].result) {
                            "succeeded" { $stagesSucceeded[$key] = $stages[$key].result }
                            "succeededWithIssues" { $stagesSucceededWithIssues[$key] = $stages[$key].result }
                            "failed" { $stagesFailed[$key] = $stages[$key].result }
                            "canceled" { $stagesCanceled[$key] = $stages[$key].result }
                            "skipped" { $stagesSkipped[$key] = $stages[$key].result }
                            default { $stagesPending[$key] = $stages[$key].result }
                        }
                    }
                    elseif ($stages[$key].state -ne 'completed') {
                        switch ($stages[$key].state) {
                            "inProgress" { $stagesInProgress[$key] = $stages[$key].state }
                            default { $stagesPending[$key] = $stages[$key].state }
                        }
                    }
                }
            }

            # Determine final result
            if ($stagesSucceeded.Count -eq $stages.Count) {
                $result = "Successful"
                if ($env:SYSTEM_DEBUG) {
                    Write-ConsoleOutput "Detected the Production deployment status as Successful ✅" -Type debug
                }
            }
            elseif ($stagesSucceededWithIssues.Count -ge 1) {
                $result = "Successful_Issues"
                if ($env:SYSTEM_DEBUG) {
                    Write-ConsoleOutput "Detected the Production deployment status as Successful with Issues △" -Type debug
                }
            }
            elseif ($stagesFailed.Count -ge 1) {
                $result = "Unsuccessful"
                if ($env:SYSTEM_DEBUG) {
                    Write-ConsoleOutput "Detected the Production deployment status as Unsuccessful ❌" -Type debug
                }
            }
            elseif (($stagesCanceled.Count -gt 1) -or ($stagesSkipped.Count -gt 1)) {
                $result = "Canceled"
                if ($env:SYSTEM_DEBUG) {
                    Write-ConsoleOutput "Detected the Production deployment status as Canceled ❌" -Type debug
                }
            }
            elseif (($stagesInProgress.Count -gt 0) -or ($stagesPending.Count -gt 0)) {
                $result = "In_Progress"
                if ($env:SYSTEM_DEBUG) {
                    Write-ConsoleOutput "Detected the Production deployment status as In Progress ⏳" -Type debug
                }
            }

        }
        catch {
            Write-Host $PSItem.ScriptStackTrace
            Write-Host $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            Write-ConsoleOutput "Determined the status of Production deployments and set the variable to: $($result)" -Type group
            Write-Host "##vso[task.setvariable variable=PRODUCTION_STAGE_STATUS;isOutput=true]$($result)"
            Write-ConsoleOutput -EndGroup
        }
    }

    end {
    }
}