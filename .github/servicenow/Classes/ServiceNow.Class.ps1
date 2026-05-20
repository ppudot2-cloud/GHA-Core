<#
.SYNOPSIS
    Defines the ServiceNow module's core data classes and creates module-scoped global instances.

.DESCRIPTION
    This file declares three PowerShell classes — ServiceNow, Body, and ChangeRecord — that
    represent the configuration, change request payload, and change record identity used
    throughout the module.

    At dot-source time (when the module is loaded) three global variables are instantiated:
        $global:config         — A ServiceNow instance holding base_uri and debug settings.
        $global:body           — A Body instance pre-populated from pipeline environment variables,
                                  used as the change request creation payload.
        $global:change_record  — A ChangeRecord instance holding identifiers for the active CR.

    All public and private functions in this module rely on these globals rather than
    accepting connection parameters on each call. The values come exclusively from
    environment variables so no credentials or URLs are hard-coded in script source.

.NOTES
    Author      : Praveen Kumar Pudota
    Created     : March 2026
    Version     : 1.0
    Purpose     : Core data model and global state for the ServiceNow PowerShell module
    Dependencies: Environment variables (see property comments below)
#>

# ---------------------------------------------------------------------------
# ServiceNow — top-level configuration object
#   $global:config is an instance of this class.
# ---------------------------------------------------------------------------
class ServiceNow {
    # Mirrors $env:SYSTEM_DEBUG (Azure DevOps debug flag).
    # When $true, Write-ConsoleOutput emits additional verbose output.
    [boolean]$debug = [System.Convert]::ToBoolean($env:SYSTEM_DEBUG)

    # ServiceNow instance base URL (e.g. https://walmart.service-now.com).
    # Sourced from $env:SERVICENOWMURI. Used by Invoke-ServiceNowRestApi to
    # build fully-qualified request URIs.
    [string]$base_uri = $env:SERVICENOWMURI

    # Pre-populated Body object for the change request payload.
    [Body]$Body = [Body]::New()

    # Pre-populated ChangeRecord object for the active change request.
    [ChangeRecord]$ChangeRecord = [ChangeRecord]::New()
}

# ---------------------------------------------------------------------------
# Body — maps directly to ServiceNow change_request table fields.
#   $global:body is an instance of this class, used when POSTing a new CR.
# ---------------------------------------------------------------------------
class Body {
    # Change type (e.g. 'standard', 'emergency'). From $env:SERVICENOWCHANGETYPE.
    [string]$type = $env:SERVICENOWCHANGETYPE

    # Assignment group name in ServiceNow. From $env:SERVICENOWASSIGNMENTGROUP.
    [string]$assignment_group = $env:SERVICENOWASSIGNMENTGROUP

    # Long-form description of the change. From $env:SERVICENOWDESCRIPTION.
    [string]$description = $env:SERVICENOWDESCRIPTION

    # Short description (ticket title). From $env:SERVICENOWSHORTDESCRIPTION.
    [string]$short_description = $env:SERVICENOWSHORTDESCRIPTION

    # Azure DevOps pipeline metadata string. From $env:SERVICENOWPIPELINEMETADATA.
    [string]$x_moms_azpipeline_metadata = $env:SERVICENOWPIPELINEMETADATA

    # Unique build identifier for the triggering pipeline run. From $env:BUILD_UNIQUE_IDENTIFIER.
    [string]$u_deploy_id = $env:BUILD_UNIQUE_IDENTIFIER

    # Target release environment (e.g. 'PROD', 'UAT'). From $env:SERVICENOWRELEASEENVIRONMENT.
    [string]$u_release_environment = $env:SERVICENOWRELEASEENVIRONMENT

    # Business justification for the change. From $env:SERVICENOWJUSTIFICATION.
    [string]$justification = $env:SERVICENOWJUSTIFICATION

    # Test plan description. From $env:SERVICENOWTESTINGPERFORMED.
    [string]$test_plan = $env:SERVICENOWTESTINGPERFORMED

    # Step-by-step implementation plan. From $env:SERVICENOWIMPLEMENTATIONPLAN.
    [string]$implementation_plan = $env:SERVICENOWIMPLEMENTATIONPLAN

    # Post-deployment validation steps. From $env:SERVICENOWVALIDATIONPLAN.
    [string]$u_validation_plan = $env:SERVICENOWVALIDATIONPLAN

    # Backout / rollback plan. From $env:SERVICENOWBACKOUTPLAN.
    [string]$backout_plan = $env:SERVICENOWBACKOUTPLAN

    # Risk and impact analysis narrative. From $env:SERVICENOWRISKIMPACTANALYSIS.
    [string]$risk_impact_analysis = $env:SERVICENOWRISKIMPACTANALYSIS

    # Bridge/call-in details for the change window. From $env:SERVICENOWCONFERENCEBRIDGE.
    [string]$u_conference_bridge = $env:SERVICENOWCONFERENCEBRIDGE

    # ServiceNow CMDB CI (Configuration Item) linked to this change. From $env:SERVICENOWCONFIGURATIONITEM.
    [string]$scmdb_ci = $env:SERVICENOWCONFIGURATIONITEM

    # Change category. From $env:SERVICENOWCATEGORY.
    [string]$category = $env:SERVICENOWCATEGORY

    # Business service name in ServiceNow. From $env:SERVICENOWSERVICENAME.
    [string]$business_service = $env:SERVICENOWSERVICENAME

    # External reference / project ID. From $env:SERVICENOWPROJECTID.
    [string]$u_reference_1 = $env:SERVICENOWPROJECTID

    # Fixed process identifier — all pipeline-created changes use this value.
    [string]$u_change_process = 'modern_deployment_process'

    # Release record ID from the ServiceNow release management module. From $env:SERVICENOWRELEASERELEASEID.
    [string]$u_release_id = $env:SERVICENOWRELEASERELEASEID

    # Risk level (e.g. 'Low', 'Moderate', 'High'). From $env:SERVICENOWRISKLEVEL.
    [string]$risk = $env:SERVICENOWRISKLEVEL

    # Impact level (e.g. '1 - High', '2 - Medium'). From $env:SERVICENOWIMPACTLEVEL.
    [string]$impact = $env:SERVICENOWIMPACTLEVEL
}

# ---------------------------------------------------------------------------
# ChangeRecord — holds the identity fields of the active change request.
#   $global:change_record is an instance of this class.
#   Values are populated by New-ServiceNowChangeRequest via ##vso pipeline
#   variable emission, then picked up by downstream functions.
# ---------------------------------------------------------------------------
class ChangeRecord {
    # Change number (e.g. CHG0012345). From $env:SNOW_CHANGE_REQUEST_NUMBER.
    [string]$number = $env:SNOW_CHANGE_REQUEST_NUMBER

    # ServiceNow sys_id GUID for the change record. From $env:SNOW_CHANGE_REQUEST_ID.
    [string]$sys_id = $env:SNOW_CHANGE_REQUEST_ID

    # Calculated risk level string returned by ServiceNow. From $env:SNOW_CHANGE_RISK_LEVEL.
    [string]$risk_level = $env:SNOW_CHANGE_RISK_LEVEL

    # Build UID linking the change to the triggering pipeline run. From $env:BUILD_UNIQUE_IDENTIFIER.
    [string]$build_uid = $env:BUILD_UNIQUE_IDENTIFIER
}

# ---------------------------------------------------------------------------
# Global instances — created once at module load time.
# All functions in this module reference these globals directly.
# ---------------------------------------------------------------------------

# Module-wide configuration (debug flag + ServiceNow base URI)
$global:config = New-Object -TypeName ServiceNow

# Change request payload template (all fields pre-populated from env vars)
$global:body = (New-Object -TypeName ServiceNow).Body

# Active change record identity (number, sys_id, risk_level, build_uid)
$global:change_record = (New-Object -TypeName ServiceNow).ChangeRecord
