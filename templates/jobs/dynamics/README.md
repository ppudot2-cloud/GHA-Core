# templates/jobs/dynamics

In GitHub Actions, reusable workflow YML files must live under `.github/workflows/`. Unlike Azure DevOps, where job-level templates can reside anywhere in the repository, the GitHub Actions platform requires callable reusable workflows to be located within the `.github/workflows/` directory tree.

The Dynamics job-level templates for this repository are therefore located at:

```
.github/workflows/dynamics/jobs/
├── _job-build.yml
├── _job-deploy.yml
├── _job-deploy-dev.yml
├── _job-jfrog.yml
└── _job-rollback.yml
```

This `templates/jobs/dynamics/` folder exists solely to maintain structural parity with the ADO `templates/jobs/` convention used across the pipeline library. The actual callable YML files are in `.github/workflows/dynamics/jobs/` as noted above.
