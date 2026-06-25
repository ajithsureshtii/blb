# Base image — CUDA devel for potential GPU use; CPU-only build works fine on this base.
FROM nvidia/cuda:12.9.1-devel-ubuntu24.04

# ── System dependencies ────────────────────────────────────────────────────────
# build-essential, cmake     : C++ build chain (BLB requires CMake >= 3.11)
# libssl-dev                 : OpenSSL (emp-tool, SCI)
# libgmp-dev                 : GMP (SCI utils)
# libomp-dev, libgomp1       : OpenMP (LinearHE, BuildingBlocks)
# libboost-all-dev, m4       : emp-tool dependencies
# autoconf, libtool          : OpenFHE build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    libssl-dev \
    libgmp-dev \
    libomp-dev \
    libgomp1 \
    libboost-all-dev \
    m4 \
    autoconf \
    libtool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Build and install OpenFHE ──────────────────────────────────────────────────
# Pinned to v1.2.3 — check https://github.com/openfheorg/openfhe-development/releases
# for the latest stable release and update the tag accordingly.
ARG OPENFHE_TAG=v1.5.1
RUN git clone --depth 1 --branch ${OPENFHE_TAG} \
        https://github.com/openfheorg/openfhe-development.git /tmp/openfhe && \
    cmake -S /tmp/openfhe -B /tmp/openfhe/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_UNITTESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_BENCHMARKS=OFF \
        -DWITH_OPENMP=ON && \
    cmake --build /tmp/openfhe/build --parallel $(nproc) && \
    cmake --install /tmp/openfhe/build && \
    ldconfig && \
    rm -rf /tmp/openfhe

ENV WORKDIR=/root/blb
RUN mkdir -p ${WORKDIR}
WORKDIR ${WORKDIR}
