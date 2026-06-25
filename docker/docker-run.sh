#!/bin/bash

# ─────────────────────────────────────────
# Configuration — edit these
IMAGE_NAME="blb-openfhe"
DOCKERFILE="docker/Dockerfile"
DEV_IMAGE_NAME="blb-openfhe-dev"
DEV_DOCKERFILE="docker/Dockerfile.dev"
MOUNT_TARGET="/root/blb"     # path inside the container to mount into
MPC_PORT="1234"              # two-party protocol port (Alice listens, Bob connects)
# ─────────────────────────────────────────
#
# Usage:
#   ./docker/docker-run.sh                          → run the base container (with mount)
#   ./docker/docker-run.sh --build                  → build base image then run
#   ./docker/docker-run.sh --dev                    → run the dev container
#   ./docker/docker-run.sh --dev --build            → build dev image then run
#   ./docker/docker-run.sh --image myimage          → run with a custom image name
#   ./docker/docker-run.sh --no-mount               → run without mounting local directory
#   ./docker/docker-run.sh --gpus                   → run with all GPUs
#   ./docker/docker-run.sh --gpus 0                 → run with GPU device 0
#   ./docker/docker-run.sh --party alice            → attach a second terminal as Alice (server)
#   ./docker/docker-run.sh --party bob              → attach a second terminal as Bob (client)
#
# Two-party MPC workflow (two terminals on the same machine):
#   Terminal 1:  ./docker/docker-run.sh --dev           (starts container, becomes Alice)
#   Terminal 2:  ./docker/docker-run.sh --party bob     (attaches to same container as Bob)
#
# ─────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run from repo root regardless of where script is called from
cd "${SCRIPT_DIR}/.."

# Parse flags
BUILD=false
DEV=false
NO_MOUNT=false
CUSTOM_IMAGE=""
PARTY=""
GPU_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --build) BUILD=true; shift ;;
    --dev) DEV=true; shift ;;
    --no-mount) NO_MOUNT=true; shift ;;
    --image)
      if [ -z "$2" ]; then echo "❌ --image requires a name"; exit 1; fi
      CUSTOM_IMAGE="$2"; shift 2 ;;
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

# ── Attach to a running container as a second party ───────────────────────────
if [[ -n "$PARTY" ]]; then
  if [[ "$DEV" == true ]]; then
    TARGET_IMAGE="$DEV_IMAGE_NAME"
  else
    TARGET_IMAGE="${CUSTOM_IMAGE:-$IMAGE_NAME}"
  fi
  CONTAINER_NAME="${TARGET_IMAGE}-container"
  if ! docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "❌ Container '$CONTAINER_NAME' is not running. Start it first without --party."
    exit 1
  fi
  echo "🔗 Attaching to '$CONTAINER_NAME' as party: $PARTY"
  docker exec -it "$CONTAINER_NAME" /bin/bash
  exit 0
fi

# ── Resolve image name and dockerfile ─────────────────────────────────────────
if [ -n "$CUSTOM_IMAGE" ]; then
  RESOLVED_IMAGE="$CUSTOM_IMAGE"
  RESOLVED_DOCKERFILE="$DOCKERFILE"
elif [ "$DEV" = true ]; then
  RESOLVED_IMAGE="$DEV_IMAGE_NAME"
  RESOLVED_DOCKERFILE="$DEV_DOCKERFILE"
else
  RESOLVED_IMAGE="$IMAGE_NAME"
  RESOLVED_DOCKERFILE="$DOCKERFILE"
fi

# If --dev and --build, ensure base image is built first
if [ "$DEV" = true ] && [ "$BUILD" = true ]; then
  if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "🔨 Base image '$IMAGE_NAME' not found. Building it first..."
    docker build -t "$IMAGE_NAME" -f "$DOCKERFILE" .
    echo "✅ Base image build complete."
  fi
fi

# Build if requested
if [ "$BUILD" = true ]; then
  echo "🔨 Building Docker image '$RESOLVED_IMAGE' from $RESOLVED_DOCKERFILE..."
  docker build -t "$RESOLVED_IMAGE" -f "$RESOLVED_DOCKERFILE" \
    --build-arg BASE_IMAGE="$IMAGE_NAME" .
  echo "✅ Build complete."
fi

# Check the image exists
if ! docker image inspect "$RESOLVED_IMAGE" &>/dev/null; then
  echo "❌ Image '$RESOLVED_IMAGE' not found. Run with --build first:"
  echo "   ./docker/docker-run.sh --build${DEV:+ --dev}"
  exit 1
fi

# Build mount flag
if [ "$NO_MOUNT" = false ]; then
  MOUNT_FLAG="-v ${PWD}:${MOUNT_TARGET}"
  echo "📂 Mounting: $PWD → $MOUNT_TARGET"
else
  MOUNT_FLAG=""
  echo "📂 Running without mount."
fi

# Run the container
CONTAINER_NAME="${RESOLVED_IMAGE}-container"
echo "🐳 Container name: $CONTAINER_NAME"

if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  read -r -p "⚠️  Container '$CONTAINER_NAME' already exists. Remove it and start fresh? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    docker rm -f "$CONTAINER_NAME"
    echo "🗑️  Old container removed."
  else
    echo "❌ Aborted. Attach to it with: ./docker/docker-run.sh --party alice"
    exit 1
  fi
fi

if [ ${#GPU_ARGS[@]} -gt 0 ]; then
  echo "🚀 Starting '$RESOLVED_IMAGE' with GPUs: ${GPU_ARGS[*]}..."
else
  echo "🚀 Starting '$RESOLVED_IMAGE'..."
fi

docker run "${GPU_ARGS[@]}" -it \
  --name "$CONTAINER_NAME" \
  -p ${MPC_PORT}:${MPC_PORT} \
  $MOUNT_FLAG \
  "$RESOLVED_IMAGE" /bin/bash
