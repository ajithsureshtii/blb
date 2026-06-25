#!/bin/bash

# ─────────────────────────────────────────
# Image names
SEAL_IMAGE="blb-seal"
SEAL_DEV_IMAGE="blb-seal-dev"
SEAL_DOCKERFILE="docker/Dockerfile.seal"
SEAL_DEV_DOCKERFILE="docker/Dockerfile.seal.dev"

OPENFHE_IMAGE="blb-openfhe"
OPENFHE_DEV_IMAGE="blb-openfhe-dev"
OPENFHE_DOCKERFILE="docker/Dockerfile"
OPENFHE_DEV_DOCKERFILE="docker/Dockerfile.dev"

MOUNT_TARGET="/root/blb"
MPC_PORT="1234"
# ─────────────────────────────────────────
#
# Usage:
#   ./docker/docker-run.sh --backend seal                       → run SEAL base container
#   ./docker/docker-run.sh --backend seal --dev                 → run SEAL dev container
#   ./docker/docker-run.sh --backend seal --dev --build         → build SEAL dev image then run
#   ./docker/docker-run.sh --backend openfhe                    → run OpenFHE base container
#   ./docker/docker-run.sh --backend openfhe --dev              → run OpenFHE dev container
#   ./docker/docker-run.sh --backend openfhe --dev --build      → build OpenFHE dev image then run
#   ./docker/docker-run.sh --backend <seal|openfhe> --no-mount  → run without mounting local dir
#   ./docker/docker-run.sh --backend <seal|openfhe> --gpus      → run with all GPUs
#   ./docker/docker-run.sh --backend <seal|openfhe> --gpus 0    → run with GPU device 0
#   ./docker/docker-run.sh --party bob --backend <seal|openfhe> → attach second MPC party terminal
#
# Two-party MPC workflow (two terminals):
#   Terminal 1:  ./docker/docker-run.sh --backend openfhe --dev
#   Terminal 2:  ./docker/docker-run.sh --backend openfhe --party bob
#
# Side-by-side comparison:
#   ./docker/docker-run.sh --backend seal    --dev   (SEAL version on port 1234)
#   ./docker/docker-run.sh --backend openfhe --dev   (OpenFHE version on port 1235)
#
# ─────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

# Parse flags
BUILD=false
DEV=false
NO_MOUNT=false
PARTY=""
BACKEND=""
GPU_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --build) BUILD=true; shift ;;
    --dev) DEV=true; shift ;;
    --no-mount) NO_MOUNT=true; shift ;;
    --backend)
      if [[ -z "$2" || "$2" == --* ]]; then echo "❌ --backend requires seal or openfhe"; exit 1; fi
      BACKEND="$2"; shift 2 ;;
    --party)
      if [[ -z "$2" || "$2" == --* ]]; then echo "❌ --party requires alice or bob"; exit 1; fi
      PARTY="$2"; shift 2 ;;
    --gpus)
      if [[ -n "$2" && "$2" != --* ]]; then VAL="$2"; shift 2; else VAL="all"; shift; fi
      if [[ "$VAL" == "all" ]]; then GPU_ARGS=(--gpus all)
      else GPU_ARGS=(--gpus "\"device=$VAL\""); fi ;;
    *) echo "❌ Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$BACKEND" ]]; then
  echo "❌ --backend is required. Use: --backend seal  or  --backend openfhe"
  exit 1
fi

# ── Resolve names based on backend ────────────────────────────────────────────
case "$BACKEND" in
  seal)
    BASE_IMAGE="$SEAL_IMAGE"
    DEV_IMAGE="$SEAL_DEV_IMAGE"
    BASE_DOCKERFILE="$SEAL_DOCKERFILE"
    DEV_DOCKERFILE_PATH="$SEAL_DEV_DOCKERFILE"
    HOST_PORT="$MPC_PORT"
    ;;
  openfhe)
    BASE_IMAGE="$OPENFHE_IMAGE"
    DEV_IMAGE="$OPENFHE_DEV_IMAGE"
    BASE_DOCKERFILE="$OPENFHE_DOCKERFILE"
    DEV_DOCKERFILE_PATH="$OPENFHE_DEV_DOCKERFILE"
    # Use port 1235 so both backends can run simultaneously on the same host
    HOST_PORT="1235"
    ;;
  *)
    echo "❌ Unknown backend '$BACKEND'. Use seal or openfhe."
    exit 1 ;;
esac

RESOLVED_IMAGE="$( [ "$DEV" = true ] && echo "$DEV_IMAGE" || echo "$BASE_IMAGE" )"
RESOLVED_DOCKERFILE="$( [ "$DEV" = true ] && echo "$DEV_DOCKERFILE_PATH" || echo "$BASE_DOCKERFILE" )"
CONTAINER_NAME="${RESOLVED_IMAGE}-container"

# ── Attach second MPC party to a running container ────────────────────────────
if [[ -n "$PARTY" ]]; then
  if ! docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "❌ Container '$CONTAINER_NAME' is not running. Start it first without --party."
    exit 1
  fi
  echo "🔗 Attaching to '$CONTAINER_NAME' as party: $PARTY"
  docker exec -it "$CONTAINER_NAME" /bin/bash
  exit 0
fi

# ── Build base image first if building dev ─────────────────────────────────────
if [ "$DEV" = true ] && [ "$BUILD" = true ]; then
  if ! docker image inspect "$BASE_IMAGE" &>/dev/null; then
    echo "🔨 Base image '$BASE_IMAGE' not found. Building it first..."
    docker build -t "$BASE_IMAGE" -f "$BASE_DOCKERFILE" .
    echo "✅ Base image built."
  fi
fi

# ── Build ──────────────────────────────────────────────────────────────────────
if [ "$BUILD" = true ]; then
  echo "🔨 Building '$RESOLVED_IMAGE' from $RESOLVED_DOCKERFILE..."
  docker build -t "$RESOLVED_IMAGE" -f "$RESOLVED_DOCKERFILE" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" .
  echo "✅ Build complete."
fi

if ! docker image inspect "$RESOLVED_IMAGE" &>/dev/null; then
  echo "❌ Image '$RESOLVED_IMAGE' not found. Run with --build first."
  echo "   ./docker/docker-run.sh --backend $BACKEND${DEV:+ --dev} --build"
  exit 1
fi

# ── Mount ──────────────────────────────────────────────────────────────────────
if [ "$NO_MOUNT" = false ]; then
  MOUNT_FLAG="-v ${PWD}:${MOUNT_TARGET}"
  echo "📂 Mounting: $PWD → $MOUNT_TARGET"
else
  MOUNT_FLAG=""
  echo "📂 Running without mount."
fi

# ── Remove stale container ─────────────────────────────────────────────────────
if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  read -r -p "⚠️  Container '$CONTAINER_NAME' already exists. Remove it and start fresh? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    docker rm -f "$CONTAINER_NAME"
    echo "🗑️  Old container removed."
  else
    echo "ℹ️  Attach a second terminal with: ./docker/docker-run.sh --backend $BACKEND --party bob"
    exit 1
  fi
fi

# ── Run ────────────────────────────────────────────────────────────────────────
[ ${#GPU_ARGS[@]} -gt 0 ] && echo "🚀 Starting '$RESOLVED_IMAGE' [backend: $BACKEND] with GPUs: ${GPU_ARGS[*]}..." \
                           || echo "🚀 Starting '$RESOLVED_IMAGE' [backend: $BACKEND]..."
echo "🐳 Container: $CONTAINER_NAME   MPC port: $HOST_PORT → $MPC_PORT"

docker run "${GPU_ARGS[@]}" -it \
  --name "$CONTAINER_NAME" \
  -p ${HOST_PORT}:${MPC_PORT} \
  $MOUNT_FLAG \
  "$RESOLVED_IMAGE" /bin/bash
