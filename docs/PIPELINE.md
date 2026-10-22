# Pipeline operations (maintainers)

How the mirror and build pipeline work. To contribute patches, see
[INTEGRATION.md](INTEGRATION.md).

## Repository branch layout

```
ubuntu-qcom-kernel
│
├── main branch                       ← CI orchestrator: workflows, scripts, docs
│   ├── .github/workflows/
│   │   ├── fetch-source-pkg.yml      ← manual incremental mirror sync
│   │   ├── bootstrap-history.yml     ← one-time history seed
│   │   ├── build-kernel.yml          ← build .deb packages (+ reusable workflow_call)
│   │   ├── premerge-main.yml         ← pre-merge build check for PRs to main
│   │   └── premerge-distro-validation.yml ← trusted distro image validation orchestrator
│   ├── scripts/                      ← sync-mirror.sh, seed-history.sh (self-documenting)
│   └── README.md
│
├── resolute-qcom branch              ← upstream Ubuntu kernel mirror (SYNC-ONLY)
│   └── immutable tag per upload: Ubuntu-qcom-X.Y.Z-A.B
│
├── resolute-qcom-devel branch        ← developer integration branch (see INTEGRATION.md)
│   └── .github/workflows/premerge-pr.yml  ← pre-merge PR build check (lives here, not on main)
│
└── resolute-qcom-seed branch         ← transient bootstrap staging (only during a seed)
```

`resolute-qcom` shares no history with `main` (the CI orchestrator); it holds the
upstream kernel tree the packages are built from.

## How it works

`resolute-qcom` mirrors the upstream Ubuntu kernel: each upload is fetched and
frozen under an immutable `Ubuntu-qcom-X.Y.Z-A.B` tag. A one-time bootstrap seeds
the branch; thereafter an incremental sync advances it per new upstream upload and
triggers a build. Builds produce `.deb` packages uploaded to a private S3 bucket
(no GitHub artifacts or releases). Qualcomm contributions land on `resolute-qcom-devel`,
never on the mirror.

Upstream source: [https://git.launchpad.net/~carmel-team/ubuntu/+source/linux/+git/resolute](https://git.launchpad.net/~carmel-team/ubuntu/+source/linux/+git/resolute).

## Running it

The maintenance workflows below are manual (`Actions → … → Run workflow`, or via `gh`):

```bash
# Sync the mirror to the latest upstream upload (no inputs; idempotent).
gh workflow run fetch-source-pkg.yml --repo qualcomm-linux/ubuntu-qcom-kernel

# Build .deb packages. Defaults to resolute-qcom-devel HEAD; set the suite input to
# resolute-qcom for the mirror, or kernel_version for an exact tag. The dbgsym
# input (default true) also builds the unstripped -dbgsym.ddeb.
gh workflow run build-kernel.yml --repo qualcomm-linux/ubuntu-qcom-kernel

# One-time only, before the first sync: seed resolute-qcom with history (into
# resolute-qcom-seed, which a human then promotes to the live branch).
gh workflow run bootstrap-history.yml --repo qualcomm-linux/ubuntu-qcom-kernel
```

PRs into `resolute-qcom-devel` get a pre-merge build check (`premerge-pr.yml` on
that branch), which calls `build-kernel.yml` with `flavours=qcom`,
`dbgsym=false`, and `s3_prefix=premerge` (binary-indep is always built
regardless of `flavours`). Its packages are uploaded to S3 under
`pkg/premerge/`, separate from the `pkg/temp/` prefix used by nightly and
manual `workflow_dispatch` runs.

PRs into `main` that change `.github/workflows/` or `scripts/` get their own
build check (`premerge-main.yml`). It builds `resolute-qcom-devel` with the
PR's `build-kernel.yml` and scripts, using `flavours=qcom` and `dbgsym=false`,
and uploads nothing.

After the pre-merge kernel workflow completes, `premerge-distro-validation.yml`
runs from the trusted `main` branch through `workflow_run`. It resolves the PR
from the triggering kernel run and, once a required reviewer of the
`On Target Validation` environment approves the run, dispatches a validated
request to the internal qcom-distro-images repository. Every PR waits for that
approval, whoever opened it; the kernel build itself is not gated. The internal
receiver calls its local reusable workflow and builds the fixed Resolute IoT
server and desktop matrix using only the Canonical kernel packages from that
exact premerge build.

The two image tarballs are uploaded alongside the kernel packages under the same
`pkg/premerge/ubuntu-qcom-kernel/<run-id>-<attempt>/` directory. A
`distro-validation.json` completion marker is written only after both image
uploads are verified. qcom-distro-images returns the distro build ID and result
through a repository dispatch callback. The Canonical callback handler verifies
the kernel run, distro run, PR identity, and S3 completion marker before reporting
the final result on the PR head commit. A Check Run named
`qcom-distro-images/canonical-premerge` starts before the distro request and is
completed only after the callback is validated. The request ID is stored as the
Check Run external ID so retries update the same validation and superseded runs
cannot overwrite a newer result. The existing commit status is published in
parallel during the transition. The untrusted PR workflow receives no repository
secrets, and neither side polls the other workflow.
