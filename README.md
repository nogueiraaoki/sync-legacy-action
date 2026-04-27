# Sync Legacy Action

Reusable GitHub Action that syncs functional changes from a legacy repository to another repository by creating or updating a pull request.

It is useful when:

- one repository is still the source of truth for application code
- another repository has repo-specific deployment files
- some paths must intentionally stay different, such as `.k8s/`, `charts/`, or `.github/workflows/`
- the target repository can be in the same account, another organization, or another private repository

## What it does

The action:

1. reads the files changed by the triggering event
2. skips configured allowed-difference paths
3. clones the target repository
4. copies changed functional files and removes deleted functional files
5. leaves target-only files untouched
6. pushes a sync branch to the target repository
7. creates or updates a pull request with origin metadata

## Requirements

In the source repository, create a secret named `NEW_REPO_PAT`.

For a fine-grained PAT, grant access to the target repository with:

- `Contents: Read and write`
- `Pull requests: Read and write`
- `Issues: Read and write` if you want the action to create or update the PR label
- `Metadata: Read`

For cross-organization sync, the token owner must have access to the target organization and repository.

## Basic usage

Create `.github/workflows/sync-to-new.yml` in the legacy repository:

```yaml
name: Sync to new repository

on:
  pull_request:
    types: [closed]
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: read

jobs:
  sync:
    if: github.event_name == 'workflow_dispatch' || github.event_name == 'push' || (github.event_name == 'pull_request' && github.event.pull_request.merged == true && github.event.pull_request.base.ref == 'main')
    runs-on: ubuntu-latest
    steps:
      - name: Checkout legacy repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Sync functional changes
        uses: nogueiraaoki/sync-legacy-action@v1
        with:
          target-owner: nogueiraaoki
          target-repo: new-repo
        env:
          GH_TOKEN: ${{ secrets.NEW_REPO_PAT }}
```

## Cross-organization usage

If the source repository is `org-a/legacy-repo` and the target repository is `org-b/new-repo`:

```yaml
- name: Sync functional changes
  uses: nogueiraaoki/sync-legacy-action@v1
  with:
    target-owner: org-b
    target-repo: new-repo
    sync-branch: sync/from-legacy
          allowed-differences: ".k8s/,charts/,.github/workflows/sync-to-new.yml,.github/workflows/new-only-ci.yml"
  env:
    GH_TOKEN: ${{ secrets.NEW_REPO_PAT }}
```

The action automatically records the source repository from `github.repository`, so the PR body will include:

```text
Origem-Repo: org-a/legacy-repo
Destino-Repo: org-b/new-repo
```

## Manual full sync

By default, `workflow_dispatch` behaves like an incremental sync for the checked out commit. It does not copy every legacy file into the target repository.

You can force a full sync explicitly:

```yaml
- uses: nogueiraaoki/sync-legacy-action@v1
  with:
    target-owner: nogueiraaoki
    target-repo: new-repo
    full-sync: "true"
  env:
    GH_TOKEN: ${{ secrets.NEW_REPO_PAT }}
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `target-owner` | yes |  | Owner or organization for the target repository. |
| `target-repo` | yes |  | Target repository name. |
| `target-base-branch` | no | `main` | Base branch in the target repository. |
| `sync-branch` | no | `sync/from-legacy` | Branch created or updated in the target repository. |
| `source-path` | no | `.` | Path to the checked out source repository. |
| `allowed-differences` | no | `.k8s/,charts/,.github/workflows/` | Comma-separated ignored paths. Entries ending in `/` ignore a directory prefix; other entries ignore one exact file path. |
| `pr-title` | no | `Sync from legacy` | Pull request title. |
| `pr-label` | no | `sync-from-legacy` | Pull request label. Use an empty value to skip labels. |
| `commit-message` | no | `Sync functional changes from legacy` | Commit message used on the target sync branch. |
| `full-sync` | no | `false` | Sync all tracked functional files instead of only event changes. |

## Outputs

| Output | Description |
| --- | --- |
| `sync-needed` | `true` when functional changes were found. |
| `pr-url` | Created or updated pull request URL. |
| `target-branch` | Target sync branch. |

## Notes

- The source repository must be checked out before using this action.
- Use `fetch-depth: 0` so the action can diff commits correctly.
- The target repository can be private or public as long as `GH_TOKEN` has access.
- The action does not merge the PR. Review and merge stay manual.
- Target-only files remain in the target repository. The action only applies legacy changes that are not ignored.
