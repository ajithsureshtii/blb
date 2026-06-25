# Docker Setup

Two backends are supported, each with its own image pair:

| Backend | Branch | Base image | Dev image | MPC port |
|---------|--------|------------|-----------|----------|
| `seal` | `main` | `blb-seal` | `blb-seal-dev` | 1234 |
| `openfhe` | `openfhe-migration` | `blb-openfhe` | `blb-openfhe-dev` | 1235 |

- **Base image** — system dependencies only. Used as a build cache layer.
- **Dev image** — builds the SCI project on top of the base, adds Python/HuggingFace deps for BERT weight extraction.

Both images can run simultaneously on the same server without port conflicts.

---

## Prerequisites

- Docker installed and running
- NVIDIA Container Toolkit (optional, for GPU access)

---

## Quick start

All commands are run from the **repo root**, not from inside `docker/`.

### Build and run the SEAL version (original BLB)

```bash
git checkout main
./docker/docker-run.sh --backend seal --dev --build
```

### Build and run the OpenFHE version

```bash
git checkout openfhe-migration
./docker/docker-run.sh --backend openfhe --dev --build
```

> The `--build` flag is only needed the first time, or after you change a Dockerfile.
> Subsequent runs omit it:
> ```bash
> ./docker/docker-run.sh --backend openfhe --dev
> ```

---

## All flags

```
--backend seal|openfhe    Required. Select which FHE backend to use.
--dev                     Run the dev image (has SCI built + Python deps).
                          Omit to run the base image only.
--build                   Build the image before running.
--no-mount                Run without mounting the local repo into the container.
                          Default: repo root is mounted at /root/blb inside the container.
--gpus                    Pass all GPUs into the container.
--gpus 0                  Pass GPU device 0 only.
--gpus 0,1                Pass GPU devices 0 and 1.
--party alice|bob         Attach a second terminal to an already-running container
                          (for two-party MPC runs). See below.
```

---

## Two-party MPC runs

BLB's protocol requires two parties (Alice = server, Bob = client) connected over a socket.
The simplest setup is two terminals into the same container.

**Terminal 1** — start the container (you become Alice):
```bash
./docker/docker-run.sh --backend openfhe --dev
# inside the container:
./bin/ckks_bert_large_main r=1 p=1234
```

**Terminal 2** — attach as Bob:
```bash
./docker/docker-run.sh --backend openfhe --party bob
# inside the container:
./bin/ckks_bert_large_main ip=127.0.0.1 r=2 p=1234
```

The same pattern works for the SEAL backend — just replace `openfhe` with `seal`.

---

## Running both backends simultaneously

Both images can run at the same time on the same machine. They use different host ports
(SEAL → 1234, OpenFHE → 1235) so there is no conflict.

```bash
# Terminal A — SEAL version
git checkout main
./docker/docker-run.sh --backend seal --dev

# Terminal B — OpenFHE version
git checkout openfhe-migration
./docker/docker-run.sh --backend openfhe --dev
```

---

## Live development (mount mode)

By default, the local repo root is mounted into the container at `/root/blb`.
This means edits you make on the host are immediately visible inside the container —
you do not need to rebuild the image for source changes.

You do need to rebuild inside the container after editing:
```bash
# inside the container
cd /root/blb/SCI/build
make -j$(nproc)
```

To run without the mount (use only the image's baked-in copy of the code):
```bash
./docker/docker-run.sh --backend openfhe --dev --no-mount
```

---

## Updating the OpenFHE version

The OpenFHE version is pinned in `docker/Dockerfile` via the `OPENFHE_TAG` build arg
(currently `v1.5.1`). To build with a different version:

```bash
docker build --build-arg OPENFHE_TAG=v1.5.2 -f docker/Dockerfile -t blb-openfhe .
```

---

## File reference

```
docker/
├── Dockerfile            OpenFHE base image (builds + installs OpenFHE v1.5.1)
├── Dockerfile.dev        OpenFHE dev image  (builds SCI + Python/HuggingFace deps)
├── Dockerfile.seal       SEAL base image    (system deps only; SEAL auto-built by CMake)
├── Dockerfile.seal.dev   SEAL dev image     (builds SCI + Python/HuggingFace deps)
├── docker-run.sh         Unified run script
└── README.md             This file
```
