# Consolidated release workflow: fork test

The draft combines Stage and Publish in `.github/workflows/release_publish.yml`.
It removes the scheduled Conda-readiness scan and the separate Stage workflow.
The Conda environment gate keeps one workflow run waiting between staging and
public publication. Production use requires a separately provisioned production
App, exact Unreal recipe correlation, and the `conda-release` protection rule.
`EVENT_DRIVEN_CONDA_RELEASE_ENABLED` is an explicit production opt-in; this draft
does not provision or validate that production configuration.

## Fork execution

Dispatch on `kavmur/deadline-cloud-for-unreal-engine`, branch
`codex/conda-release-workflow`, with `test_mode=true`.

1. Validate the fork and dev example metadata.
2. Run the repository's full Python unit-test/lint/build matrix using the
   existing Code Quality reusable workflow.
3. Build real Unreal wheel and source distribution artifacts from the exact
   workflow commit; record their SHA-256 hashes in a GitHub artifact.
4. Pause at the existing personal App's `conda-poc` environment.
5. Have dev Lambda/SQS report Conda progress and approve after DocsUpdate
   readiness.
6. Download the same staged artifacts, check their hashes, and run `twine check`.

The test uses the supplied C4D recipe solely as the external gate example.
The built packages are Unreal packages. It does not claim that the C4D version
is an Unreal release dependency.

Use `conda_event_mode=synthetic`, `conda_version=0.12.3`, and the supplied
recipe commit for a controlled dev demonstration. Use `native`, version
`1.0.0`, to wait for the actual subscribed change.

No tags, GitHub releases, or PyPI uploads are created in test mode. Shared AWS
integration/UI/E2E tests, release CodeBuild staging, and signing are skipped.
No PROD or GAMMA resource is used to execute this test. No AWS state store or
periodic checker is added.

This test verifies workflow ordering, real package builds, protected waiting,
progress updates, and same-run artifact validation after resumption. It does
not verify production CodeArtifact staging, AWS integration tests, signing,
public publishing, or live native-event compatibility.
