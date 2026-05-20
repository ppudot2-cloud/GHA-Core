<#
.SYNOPSIS
    Submits scan and test artifact records to the ServiceNow audit trail table for the
    active change request.

.DESCRIPTION
    Processes a directory of audit artifact files (Checkmarx, SonarQube, BlackDuck, functional
    test reports, etc.) and creates a corresponding record in the ServiceNow
    u_azure_devops_audit_trail table for each recognised file type.

    End-to-end behaviour:

        1. begin block — If -ScanExempt is specified, creates three placeholder files
           (RiskSummaryReport, cxReport, SonarQube) in $AuditTrailPath to represent
           exemption from each scan type. Then enumerates all files in the directory.

        2. process block — If no artifact files are found, updates the change request
           short_description and work_notes via a PUT call to indicate missing artifacts.
           For each recognised file (matched by wildcard against the file name), posts a
           record to u_azure_devops_audit_trail with:
               u_change_request — change number
               u_comments       — Artifactory URL (or "ScanExempt" when not exempt)
               u_gate_purpose   — type of scan (e.g. "SAST Scan", "SCA Scan")
               u_source_name    — tool name (e.g. "CheckMarx", "BlackDuck")

        3. finally block — Always logs the ServiceNow portal URL.

    NOTE: The -ScanExempt logic is inverted. When $ScanExempt is set, the file URI
    is built from the Artifactory path (correct for exempt pipelines). When $ScanExempt
    is NOT set, $fileUri = "ScanExempt" (incorrect — non-exempt pipelines should have
    a real Artifactory URL). This logic needs to be reversed.

    NOTE: The Artifactory base URL is hardcoded to https://prod.artifactory.nfcu.net/
    and must be updated to the Walmart Artifactory instance.

.PARAMETER AuditTrailPath
    The directory path containing the scan/test artifact files to submit. The function
    enumerates all files recursively within this directory.

.PARAMETER ScanExempt
    Switch. When present, creates exemption placeholder files in $AuditTrailPath before
    enumerating artifacts, indicating the pipeline is exempt from the corresponding scans.

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    None. Side effects: POST calls to ServiceNow u_azure_devops_audit_trail table.
    Optionally a PUT call to update change request short_description/work_notes.

.EXAMPLE
    Add-ServiceNowAuditTrailArtifact -AuditTrailPath "$(Build.StagingDirectory)/AuditTrail"

    Submits all recognised artifact files from the staging directory to ServiceNow.

.EXAMPLE
    Add-ServiceNowAuditTrailArtifact -AuditTrailPath "./Audit" -ScanExempt

    Creates exemption placeholder files then submits them as audit trail records.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : ServiceNow Change Management — Audit Trail Integration
    Dependencies: Invoke-ServiceNowRestApi, Write-ConsoleOutput,
                  $global:change_record (number, sys_id), $global:config (base_uri),
                  $global:body (short_description)

    Known issues:
        - ScanExempt logic is inverted: non-exempt pipelines receive $fileUri = "ScanExempt".
          Fix: swap the if/else branches so real URLs are used for non-exempt pipelines.
        - Artifactory base URL is hardcoded to prod.artifactory.nfcu.net — update to the
          Walmart Artifactory instance URL.
        - Unrecognised file names silently skip via 'continue' with no warning logged.
#>

function Add-ServiceNowAuditTrailArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $AuditTrailPath,

        [Parameter(Mandatory = $false)]
        [switch] $ScanExempt
    )

    begin {
        $ErrorActionPreference = "Stop"

        # When the pipeline is exempt from scanning, create placeholder files so that
        # downstream audit trail records are still generated with an exemption note.
        if ($ScanExempt) {
            New-Item -ItemType File -Path $AuditTrailPath -Name "RiskSummaryReport" -Value "This pipeline is exempt from Blackduck scanning."  -Force | Out-Null
            New-Item -ItemType File -Path $AuditTrailPath -Name "cxReport"          -Value "This pipeline is exempt from Checkmarx scanning."  -Force | Out-Null
            New-Item -ItemType File -Path $AuditTrailPath -Name "SonarQube"         -Value "This pipeline is exempt from SonarQube scanning."  -Force | Out-Null
        }

        # Enumerate all artifact files for processing
        $artifactFiles = Get-ChildItem -Path $AuditTrailPath -File -Recurse
    }

    process {
        try {
            if (-not $artifactFiles) {
                # No artifacts found — update the change request to note the absence
                Write-ConsoleOutput "Found no artifact files in $($AuditTrailPath). Updating change record short description..." -Type warning

                $uri                    = "/api/now/table/change_request/$($change_record.sys_id)"
                $currentShortDescription = $body.short_description
                $updatedShortDescription = "Removed due to lack of audit artifacts."
                $workNote               = "No audit artifact files found."

                $body = @{
                    'short_description' = $updatedShortDescription
                    'work_notes'        = $workNote
                }

                $json = $body | ConvertTo-Json -Compress -Depth 100
                $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Put -Body $json
                $response.result

                Write-ConsoleOutput "Successfully updated short description for $($change_record.number) from $($currentShortDescription) to $($updatedShortDescription)" -Type section
                Write-ConsoleOutput "Successfully added work note for $($change_record.number): $($workNote)" -Type section
            }

            # Target the audit trail table for each artifact submission
            $uri            = "/api/now/table/u_azure_devops_audit_trail"
            # TODO: Update to Walmart Artifactory URL
            $artifactoryUri = "https://prod.artifactory.nfcu.net/artifactory/webapp/#/artifacts/browse/tree/General/cicd-audit/"

            foreach ($file in $artifactFiles) {
                # NOTE: ScanExempt logic is inverted here — see Known Issues
                if ($ScanExempt) {
                    # Build the Artifactory URL for this artifact file
                    $filePath = ($file.FullName).Replace("$($AuditTrailPath)", "")
                    $filePath = $filePath.Replace('\', '/')   # Normalise Windows path separators
                    $filePath = $filePath.TrimStart('/')       # Remove leading slash
                    $fileUri  = "$($artifactoryUri)$($filePath)"
                }
                else {
                    # NOTE: This should be the real Artifactory URL for non-exempt pipelines
                    $fileUri = "ScanExempt"
                }

                # Reset per-file values before the switch
                $sourceName  = $null
                $gatePurpose = $null
                $comment     = $null

                # Map file name patterns to ServiceNow audit trail field values
                switch -wildcard ($file.Name) {
                    "*cxReport*"        { $sourceName = "CheckMarx";       $gatePurpose = "SAST Scan";                    $comment = "$($fileUri)" }
                    "*SonarQube*"       { $sourceName = "SonarQube";       $gatePurpose = "Code Quality Scan";            $comment = "$($fileUri)" }
                    "*RiskSummaryReport*" { $sourceName = "BlackDuck";     $gatePurpose = "SCA Scan";                     $comment = "$($fileUri)" }
                    "*smoke*"           { $sourceName = "FunctionalTests"; $gatePurpose = "Functional Tests(Smoke)";      $comment = "$($fileUri)" }
                    "*regression*"      { $sourceName = "FunctionalTests"; $gatePurpose = "Functional Tests(Regression)"; $comment = "$($fileUri)" }
                    "*all*"             { $sourceName = "FunctionalTests"; $gatePurpose = "Functional Tests(All tests)";  $comment = "$($fileUri)" }
                    "*failed*"          { $sourceName = "FunctionalTests"; $gatePurpose = "Functional Test(Failed tests)";}
                    "*newman*"          { $sourceName = "Newman";          $gatePurpose = "Newman(Functional Tests)";     $comment = "$($fileUri)" }
                    "*neoload*"         { $sourceName = "Neoload";         $gatePurpose = "Neoload(Performance Tests)";   $comment = "$($fileUri)" }
                    "*PegaDMGuardrail*" { $sourceName = "Guardrail";       $gatePurpose = "Guardrail Compliance";         $comment = "$($fileUri)" }
                    "*sarif*"           { $sourceName = "PowerAppsChecker";$gatePurpose = "Code Quality Scan";            $comment = "$($fileUri)" }
                    default             { continue }   # Unrecognised file type — skip silently
                }

                if ($null -ne $gatePurpose) {
                    # POST a new audit trail record linking the artifact to this change request
                    $body = @{
                        'u_change_request' = $change_record.number
                        'u_comments'       = $comment
                        'u_gate_purpose'   = $gatePurpose
                        'u_source_name'    = $sourceName
                    }

                    $json     = $body | ConvertTo-Json -Compress -Depth 100
                    $response = Invoke-ServiceNowRestApi -Uri $uri -RequestMethod Post -Body $json
                    $response.result

                    Write-ConsoleOutput "$($sourceName) - $($gatePurpose) Audit Trail Matrix submission successful." -Type section
                }
            }
        }
        catch {
            Write-Output $PSItem.ScriptStackTrace
            Write-Output $PSItem.Exception
            throw $PSItem.ErrorDetails.Message
        }
        finally {
            Write-ConsoleOutput "The ServiceNow Change Request URL is: $($config.base_uri)/nav_to.do?uri=change_request.do?sys_id=$($change_record.sys_id)"
        }
    }

    end {
    }
}
