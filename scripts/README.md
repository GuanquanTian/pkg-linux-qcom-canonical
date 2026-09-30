# Kernel Build Scripts

This directory contains scripts for building Ubuntu kernel .deb packages for Qualcomm platforms.

## Setup & Build Steps

### 1. Docker Access

Ensure your user can run Docker without sudo. If not already configured:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

Verify Docker access:

```bash
docker ps
```

### 2. Prepare Workspace

Create a workspace directory (you can rename `canonical-pkg` as needed):

```bash
mkdir canonical-pkg && cd canonical-pkg
```

### 3. Pull Required Repositories

#### a) Pull the CI orchestrator (main branch)

```bash
git clone --depth 1 https://github.com/qualcomm-linux/pkg-linux-qcom-canonical.git
```

#### b) Pull the kernel source (resolute-qcom-devel branch)

```bash
git clone -b resolute-qcom-devel --depth 1 https://github.com/qualcomm-linux/pkg-linux-qcom-canonical.git resolute-qcom-devel
```

#### c) Pull the Qualcomm DTB metadata

```bash
git clone https://github.com/qualcomm-linux/qcom-dtb-metadata.git
```

Make the build scripts executable:

```bash
chmod +x pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh
chmod +x pkg-linux-qcom-canonical/scripts/build-docker-image.sh
chmod +x qcom-dtb-metadata/build-dtb-image.sh
```

### 4. Configure Proxy (First Time per Machine, if Needed)

The first `docker-build-kernel.sh` run on a machine builds a local Docker image, which needs `apt-get` access to Ubuntu package mirrors. If this machine's network can't reach those mirrors directly, pass a proxy for that one build — it's only used while building the Docker image, never by the container itself or by later kernel builds on the same machine (the image is cached locally once built):

```bash
# Replace your-proxy-server:8080 with your actual proxy address
HTTP_PROXY=http://your-proxy-server:8080 \
HTTPS_PROXY=http://your-proxy-server:8080 \
./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh
```

This is a **one-time, per-machine** step.

After completing the above, your workspace structure should look like:

```
canonical-pkg/
├── pkg-linux-qcom-canonical/          # CI orchestrator (main branch)
│   ├── scripts/
│   │   ├── docker-build-kernel.sh     # Docker wrapper for builds
│   │   ├── build-kernel-deb.sh        # Core build script
│   │   ├── build-docker-image.sh      # Builds the local Docker image on demand
│   │   ├── Dockerfile.kernel-build    # Image definition used by build-docker-image.sh
│   │   ├── lib/                       # Shared helpers sourced by the scripts above
│   │   ├── README.md
│   │   └── ...
│   └── ...
├── resolute-qcom-devel/               # Kernel source (resolute-qcom-devel branch)
│   ├── debian.qcom/                   # Qualcomm-specific build config
│   ├── arch/
│   ├── drivers/
│   └── ...
├── qcom-dtb-metadata/                 # DTB metadata
│   ├── build-dtb-image.sh
│   └── ...
└── output/                            # Build artifacts (created after first build)
    ├── linux-image-*.deb
    ├── linux-modules-*.deb
    ├── linux-headers-*.deb
    └── ...
```

---

## Quick Start

After completing the setup steps above, from the workspace directory:

```bash
# uses default source directory: resolute-qcom-devel
./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh

# Specify a different source directory (relative to current directory)
./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh ./resolute-qcom-devel
```

Output packages: `./output/`

---

## Common Arguments & Environment Variables

### Arguments

```bash
./scripts/docker-build-kernel.sh [SOURCE_DIR] [ARCH] [FLAVOR] [JOBS] [VERSION_SUFFIX]
```

| Argument | Default | Description |
|----------|---------|-------------|
| `SOURCE_DIR` | `resolute-qcom-devel` | Root of kernel source tree (resolved relative to current working directory) |
| `ARCH` | `arm64` | Target architecture: `arm64` |
| `FLAVOR` | `qcom` | Kernel flavor: `qcom`, `qcom-rt`, or `all` (builds both `qcom` and `qcom-rt`) |
| `JOBS` | `8` | Parallel make jobs. Higher values scale worse than expected on incremental (mostly-unchanged) rebuilds due to scheduling overhead — override explicitly (e.g. to `$(nproc)`) for a from-scratch build on a many-core machine |
| `VERSION_SUFFIX` | (none) | Version suffix (e.g., `+g1a2b3c4` or `+myuser1`). Pass `auto` to generate from git HEAD |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IMAGE` | `kernel-build-docker:resolute-target-<ARCH>` | Docker image to use; built on demand via `build-docker-image.sh` if not already present locally |
| `OUTPUT_DIR` | `./output` (relative to current directory) | Where built `.deb` packages are placed. Set to a fixed path (relative or absolute) if you don't want the output location to depend on which directory you invoke the script from. Created on the host before the container starts, so it's never auto-created by Docker as root |
| `VERSION_SUFFIX` | (none) | Optional version suffix for the kernel package (e.g., `+v1.0`, `+myuser1`). Pass `auto` to generate from git HEAD |
| `INCREMENTAL_BUILD` | `0` | Set to `1`/`true`/`yes`/`on` to enable incremental builds where kbuild only recompiles files that actually changed. Clean builds (default) force a full `debian/rules clean` (`rm -rf debian/build debian/stamps`) ensuring a guaranteed-clean build, which is the safe default for CI and release workflows. Incremental builds are useful for local development |
| `DBGSYM` | `0` | Set to `1`/`true`/`yes`/`on` to also build the unstripped `-dbgsym.ddeb` debug symbol packages (vmlinux + modules with full debug symbols) alongside the `.deb` packages |
| `DEBEMAIL` | `build-kernel-deb@localhost` | Email for changelog entries |
| `DEBFULLNAME` | `build-kernel-deb.sh` | Full name for changelog entries |
| `HTTP_PROXY` | (none) | HTTP proxy URL for Docker image build only (e.g., `http://your-proxy-server:8080`). Only needed on first run if your network cannot access Ubuntu package mirrors directly |
| `HTTPS_PROXY` | (none) | HTTPS proxy URL for Docker image build only (e.g., `http://your-proxy-server:8080`). Only needed on first run if your network cannot access Ubuntu package mirrors directly |

---

### Incremental Builds

By design, builds are clean by default (`INCREMENTAL_BUILD=0`): build state
(`debian/build/`, `debian/stamps/`) is removed before each build, ensuring
a guaranteed-clean build. This is the safe default for CI and release workflows.

For local development, you can enable incremental builds to speed up rebuilds
when only a few files have changed:

```bash
# Enable incremental builds
INCREMENTAL_BUILD=1 ./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh resolute-qcom-devel arm64 qcom
```

Note: incremental build state persists across runs even though each build runs
in a `--rm` container, so kbuild only recompiles what changed.

---

## Argument Priority

Arguments are resolved in the following order (first match wins):

1. **Positional arguments** — passed directly to the script
2. **Environment variables** — `SOURCE_DIR`, `ARCH`, `FLAVOR`, `JOBS`, `VERSION_SUFFIX`
3. **Default values** — built into the script

`SOURCE_DIR` is resolved relative to the current working directory.

### Example

```bash
# JOBS comes from the environment variable since no 4th positional arg is given
JOBS=16 ./scripts/docker-build-kernel.sh resolute-qcom-devel arm64 qcom
# Result: SOURCE_DIR=resolute-qcom-devel, ARCH=arm64, FLAVOR=qcom, JOBS=16, VERSION_SUFFIX=(none)
```

---

## docker-build-kernel.sh

Docker wrapper script for containerized kernel builds.

### Usage

```bash
./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh [SOURCE_DIR] [ARCH] [FLAVOR] [JOBS] [VERSION_SUFFIX]
```

### Examples

```bash
# Basic build
./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh

# Only change source directory (other params use defaults)
./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh ./resolute-qcom-devel

# With custom version
./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh ./resolute-qcom-devel arm64 qcom $(nproc) +v1.0

# Auto-generate version from git
./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh ./resolute-qcom-devel arm64 qcom $(nproc) auto

# Use environment variable for version suffix
VERSION_SUFFIX=+myuser1 ./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh

# Auto-generate version via environment variable
VERSION_SUFFIX=auto ./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh

```

---

## build-docker-image.sh (build your own local Docker image)

`docker-build-kernel.sh` builds this image automatically on first use if
`kernel-build-docker:resolute-target-<ARCH>` isn't already present locally —
you normally don't need to invoke it yourself. To build (or rebuild) the
image explicitly — with build-dependencies resolved dynamically from your
actual kernel source tree's `debian/control` (via `debian/rules clean`),
rather than a hand-maintained snapshot file — use:

```bash
./pkg-linux-qcom-canonical/scripts/build-docker-image.sh [SOURCE_DIR] [ARCH]
```

This produces a local image tagged `kernel-build-docker:resolute-target-<ARCH>`
(`<ARCH>` here is the compile *target* architecture, not necessarily the
image's own native architecture — see the note below). To use a different
image instead of the default, point `docker-build-kernel.sh` at it via the
`IMAGE` environment variable:

```bash
./pkg-linux-qcom-canonical/scripts/build-docker-image.sh ./resolute-qcom-devel arm64
IMAGE=my-custom-image:tag ./pkg-linux-qcom-canonical/scripts/docker-build-kernel.sh ./resolute-qcom-devel arm64
```

Cross-compilation (e.g. building an arm64 image on an amd64 host) is
supported the same way — just pass `arm64` as `ARCH` while running on an
amd64 host, for both `build-docker-image.sh` and `docker-build-kernel.sh`.

> **Note:** `<ARCH>` in the image tag is the *target* architecture you're
> compiling for, not the image's own native architecture. `FROM
> ubuntu:resolute` always resolves to the multi-arch manifest for the build
> host, so a `resolute-target-arm64` image built on an amd64 host is still a
> native amd64 image — just one with an arm64 cross-toolchain installed
> inside it. Building on an arm64 host would instead be a native arm64
> image with the cross-toolchain layer skipped.

> **Note:** `build-docker-image.sh` builds `FROM` the official
> `docker.io/library/ubuntu:resolute` image when available, falling back to
> `public.ecr.aws/ubuntu/ubuntu:resolute` for whichever registry hasn't
> published that tag. Both are genuine multi-arch manifest lists, so this
> fallback doesn't affect which architecture the resulting image runs as on
> your build host.

> **Note:** `docker-build-kernel.sh` only builds the image if it's missing
> locally — it never rebuilds an already-cached one, even after
> `Dockerfile.kernel-build` changes. If you pull an update to this repo that
> touches the Dockerfile (e.g. a new base tool), remove the stale image so
> it gets rebuilt on the next run:
>
> ```bash
> docker rmi kernel-build-docker:resolute-target-<ARCH>
> ```

---

## Create FIT dtb.bin

After kernel build completes, create the FIT dtb.bin image:

```bash
cd qcom-dtb-metadata

# Build dtb.bin from kernel modules deb
sudo ./build-dtb-image.sh --soc hamoa purwa qcs6490 qcs8275 qcs9075 --kernel-deb {kernel-deb-path}/linux-modules-7.0.0-1006-qcom_7.0.0-1006.8_arm64.deb --out dtb.bin --prune
```

Output: `dtb.bin`

---

## Update Kernel and DTB

### 1. Install Kernel on Target Machine

Example for kernel 7.0.0-1006-qcom:

```bash
# Required
sudo dpkg -i linux-modules-7.0.0-1006-qcom_7.0.0-1006.8_arm64.deb
sudo dpkg -i linux-image-7.0.0-1006-qcom_7.0.0-1006.8_arm64.deb

# Optional: kernel headers (for out-of-tree module development)
# linux-headers-*-qcom depends on the arch-independent linux-qcom-headers-*
# package, so install that first.
sudo dpkg -i linux-qcom-headers-7.0.0-1006_7.0.0-1006.8_all.deb
sudo dpkg -i linux-headers-7.0.0-1006-qcom_7.0.0-1006.8_arm64.deb
```

### 2. Flash dtb.bin

First, ensure the `qdl` tool is installed:

```bash
# Install qdl (Qualcomm Download tool)
sudo apt-get install -y qdl
```

Then flash the dtb.bin:

```bash
qdl --storage spinor xbl_s_devprg_ns.melf write dtb_a dtb.bin
```

---

## License

SPDX-License-Identifier: BSD-3-Clause

See individual script headers for details.
