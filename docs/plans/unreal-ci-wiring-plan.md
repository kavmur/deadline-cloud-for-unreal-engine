# Unreal C++ Automation Tests → CI Wiring Plan

**Purpose:** Action plan for the agent/engineer wiring the UnrealDeadlineCloudService
C++ automation tests into CI/CD. This is the *what-to-do*; the companion
`unreal-ci-headless-tests-context.md` is the *what's-true-today* reference. Read that
first, then work this list top to bottom.

**Goal:** A GitHub Actions job that, on PRs to `mainline`, builds the plugin for the
target UE version(s) and runs the offline `DeadlineCloud.*` automation suite headless,
failing the PR on any `Result={Fail}`.

---

## Prerequisites / open questions to resolve first

These gate everything below. Resolve them before writing YAML.

- [ ] **Runner infra.** GitHub-hosted Windows runners do **not** have Unreal Engine
  (~100 GB toolchain). A self-hosted Windows runner with UE 5.6 (and/or 5.7) installed is
  required. `integration_tests.yml` and `e2e_tests.yml` already build/run against UE —
  **confirm what runner they use** (`runs-on:` in their reusable workflows under
  `aws-deadline/.github`) and whether that runner can be reused or a new label is needed.
- [ ] **Engine version matrix.** Verified passing on UE 5.6 and 5.7. Decide whether CI
  runs both (matrix) or just the primary (5.6). Set `UE_INSTALL_ROOT` per runner.
- [ ] **Reusable-workflow convention.** The org keeps reusable workflows in
  `aws-deadline/.github`. Decide: add a new reusable workflow there (mirrors
  `reusable_integration_test.yml`) called from a thin `unreal_automation_tests.yml` in
  this repo, OR keep it self-contained in this repo. Match whatever the maintainers prefer.
- [ ] **Test project source.** CI needs a plugin-enabled `.uproject` to run against. Decide
  the source: (a) a bare fixture project committed/generated in-repo, or (b) a project
  provisioned on the runner. Must have `Provider=None` (no source control) — see the
  source-control trap below.

---

## Action items

### 1. Provision / confirm the CI test project
- [ ] Ensure a plugin-enabled project is available to the runner with **no source control**
  (`Provider=None`, or no `SourceControlSettings.ini`). A bare project is sufficient for the
  offline suite; it will *not* have MRQ/render content (see item 4 caveats).
- [ ] Do **not** reuse a Perforce-configured project on a runner without a P4 ticket — the
  startup connect error gets escalated into spurious test failures (documented trap).

### 2. Build & install step
- [ ] `python scripts/build_plugin.py --ueversion <v> --install --test`
  (`--test` is mandatory — copies the `openjd_templates` fixtures the specs read).
- [ ] **Verify the build actually happened**, not just exit code:
  - compile: `error C[0-9]` count == 0 in the UAT log **and** `BUILD SUCCESSFUL` present.
    UAT log: `~/AppData/Roaming/Unreal Engine/AutomationTool/Logs/C+Program+Files+Epic+Games+UE_<ver>/Log.txt`
  - install: fresh mtime on
    `<engine>/Engine/Plugins/UnrealDeadlineCloudService/Binaries/Win64/UnrealEditor-UnrealDeadlineCloudService.dll`
- [ ] Ensure no `UnrealEditor(-Cmd).exe` is running before install (locked-DLL → `WinError 5`;
  the compile can succeed while install fails). Kill stale editors in a pre-step.

### 3. Headless test-run step
- [ ] Run:
  ```
  "<engine>/Engine/Binaries/Win64/UnrealEditor-Cmd.exe" "<project>.uproject" \
    -RenderOffScreen -unattended -nosplash -NoSound \
    -ExecCmds="Automation RunTests <IDs>" \
    -testexit="Automation Test Queue Empty" -log
  ```
- [ ] Scope `<IDs>` to `DeadlineCloud` (avoids ~90 vendored third-party Python self-test
  "failures"), and **exclude `DeadlineCloud.Integration.CreateJob`** from this offline job
  (needs AWS creds — see item 4). Join a curated ID list with `+`.
- [ ] Use `-RenderOffScreen`, **not** `-nullrhi` — the UI specs carry `NonNullRHI`.

### 4. Result parsing & gating
- [ ] Parse the **UE log** (`<project>/Saved/Logs/<Project>.log`), not the process exit code,
  for `Test Completed. Result={Success|Fail}`. Fail the job on any `Result={Fail}`.
- [ ] Also fail if the expected number of tests didn't complete (guards against a crash that
  silently runs zero tests and exits clean).
- [ ] Do **not** rely on `-ReportExportPath` `index.json` — often empty on `-testexit` runs,
  and UTF-8-BOM when present. If used at all, decode with `utf-8-sig` and treat empty as
  "parse the log instead," not "crash."
- [ ] Upload the UE log (and UAT log) as a build artifact for post-mortem on failures.

### 5. Credentialed tests (separate, optional job)
- [ ] `DeadlineCloud.Integration.CreateJob` needs a live AWS Deadline Cloud profile + real
  MRQ/render content. Run it only where creds exist — mirror `integration_tests.yml`'s OIDC
  setup (`id-token: write`, `secrets: inherit`). Either a separate job or gate behind a
  creds-available check. Without creds it logs `credentials are expired` → 300s timeout →
  `Result={Fail}`.
- [ ] Note: `MRQJobUI` does **not** need creds (builds from fixtures + in-memory MRQ queue),
  but has a pre-existing headless reliability issue (see item 6). Keep it out of the
  must-pass gate until that's fixed, or mark expected-fail.

### 6. Close known test gaps (can land in parallel; tracked in follow-ups doc)
- [ ] Add the focused headless unit test for `SDeadlineCloudStringWidget::OnTextCommitted`
  (see `unreal-ci-test-followups.md` item 1) so the shared commit gate is covered
  independent of keyboard focus.
- [ ] Triage `MRQJobUI` headless: the `#AttachmentArrayElement.Value//...//<SEditableTextBox>`
  widget isn't visible/interactable headless, and its `EditableTextTest` assert
  (`"Test" == ExpectedValue`) is logically broken (compares a literal to itself, not the
  widget read-back). Fix or quarantine before adding to the gate.
- [ ] Confirm/close the numeric (`SDeadlineCloudFloat/IntWidget`) and path
  (`SDeadlineCloudFilePathWidget`) commit-on-Enter reliability headless (pre-existing,
  keyboard-only paths).

### 7. Wire the trigger & finalize
- [ ] `on:` PRs to `mainline`/`release`/`patch_*` + `mainline` push (match `code_quality.yml`),
  plus `workflow_dispatch` for manual runs.
- [ ] Start as a **non-blocking / informational** check for a few runs to confirm stability on
  the runner, then promote to a required status check once green consistently.
- [ ] Document the new job in `DEVELOPMENT.md` (how to reproduce the CI run locally).

---

## Suggested rollout order

1. Resolve prerequisites (runner, engine matrix, project source).
2. Land item 6 test-gap fixes first (so the gated suite is trustworthy) — or explicitly
   scope them out of the initial gate.
3. Stand up the job (items 1–4) as non-blocking on UE 5.6 only.
4. Verify stability across several PRs; add UE 5.7 matrix if desired.
5. Promote to required check.
6. Add the credentialed `CreateJob`/e2e job (item 5) separately if wanted.

---

## Pointers

- Context/reference: `docs/plans/unreal-ci-headless-tests-context.md`
- Test-gap tracking: `docs/plans/unreal-ci-test-followups.md`
- Build script: `scripts/build_plugin.py`
- Tests: `src/unreal_plugin/Source/UnrealDeadlineCloudService/Private/Tests/`
- Existing CI (patterns to mirror): `.github/workflows/{code_quality,integration_tests,e2e_tests}.yml`
- Reusable org workflows: `aws-deadline/.github`
- Merged input-mechanics PR: #354
