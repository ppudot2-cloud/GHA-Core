# GHA-Core — Power Platform CI/CD Reusable Library

Shared GitHub Actions library for Power Platform pipelines. Contains all reusable workflows, composite actions, and PowerShell scripts. Called by [GHA-Dynamics](https://github.com/ppudot2-cloud/GHA-Dynamics) project repos.

> **Do not trigger pipelines from this repo.** All workflows here are `workflow_call` reusables — they have no triggers of their own.

---

## Structure

```
GHA-Core/
├── .github/
│   ├── workflows/               # Reusable workflows (MUST be at root — GitHub constraint)
│   │   ├── _job-build.yml       # Single-solution build job
│   │   ├── _job-rollback.yml    # Single-environment rollback job
│   │   ├── _stage-build.yml     # Build stage (matrix per solution)
│   │   ├── _stage-deploy-chain.yml  # Sequential deploy chain (alternative architecture)
│   │   └── _stage-export.yml    # Export stage
│   ├── actions/dynamics/        # Composite actions
│   │   ├── ci-bootstrap/        # Checkout + OIDC login + AKV secrets + merge vars
│   │   ├── deploy-all-solutions/# Main deploy orchestrator for one environment
│   │   ├── export-config-data/  # Config migration data export
│   │   ├── export-solution/     # PAC solution export
│   │   ├── import-solution/     # PAC solution import (all variants)
│   │   ├── jfrog-upload/        # JFrog Artifactory upload
│   │   ├── pac-install/         # Install PAC CLI
│   │   ├── pack-solution/       # Version stamp + pack ZIPs
│   │   ├── post-deploy/         # JFrog Prod tag + deploy summary
│   │   ├── pre-deploy-checks/   # Blocking check + version compare
│   │   └── solution-checker/    # PAC Solution Checker + SARIF
│   ├── scripts/dynamics/        # PowerShell scripts (14 scripts)
│   │   ├── Resolve-SolutionMatrix.ps1
│   │   ├── Set-SolutionVersion.ps1
│   │   ├── Remove-ManagedTag.ps1
│   │   ├── New-MockSolutionZip.ps1
│   │   ├── Invoke-SolutionCheckerSim.ps1
│   │   ├── Export-ConfigDataSim.ps1
│   │   ├── Invoke-ExportCommitSim.ps1
│   │   ├── Invoke-BlockingCheck.ps1
│   │   ├── Compare-SolutionVersion.ps1
│   │   ├── Merge-Variables.ps1
│   │   ├── Invoke-JFrogAction.ps1
│   │   ├── Write-BuildSummary.ps1
│   │   ├── Write-DeploySummary.ps1
│   │   └── Write-PipelineSummary.ps1
│   ├── config/
│   │   └── global-vars.yml      # Org-wide default variables
│   └── service-now/             # ServiceNow integration placeholders
└── README.md
```

---

## How callers use this repo

1. `ci-bootstrap` checks out GHA-Core to `.ci/` on every runner using `GHA_CORE_PAT`
2. Workflows are called via `uses: ppudot2-cloud/GHA-Core/.github/workflows/{name}@main`
3. Actions are called via `uses: ppudot2-cloud/GHA-Core/.github/actions/dynamics/{name}@main`
4. Scripts are called via `& .ci/.github/scripts/dynamics/{Script}.ps1`

---

## Documentation

Full documentation lives in GHA-Dynamics. See [GHA-Dynamics/docs/PIPELINE_REFERENCE.md](https://github.com/ppudot2-cloud/GHA-Dynamics/blob/main/docs/PIPELINE_REFERENCE.md) for a complete reference of every workflow, action, and script.
