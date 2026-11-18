#!/bin/bash
# Builds the fork's CUDA engine for this box (sm_61 GP104 + sm_86), with MMQ and the vendored ggml.
# The worktree has no third_party/llama.cpp submodule, so it builds from third_party/strata-ggml (the default) instead
# of -DSTRATA_GGML_DIR: no other checkout is written to, and every A/B of the fork uses the same binary anyway.
#
#   nice -n 19 bash bench/ab/build_fork.sh          # ~1 h on this 2x Xeon; do not run it during a benchmark
set -euo pipefail
cd /home/almir/models-ssd/Strata-pascal || exit 1
JOBS=${JOBS:-6}
cmake -S . -B build-cuda12 -DCMAKE_BUILD_TYPE=Release \
  -DSTRATA_ENABLE_CUDA=ON -DSTRATA_ENABLE_HIP=OFF -DSTRATA_ENABLE_SYCL=OFF \
  -DSTRATA_EXPERIMENTAL_SM60=ON -DSTRATA_MMQ=ON \
  -DSTRATA_ISA_FLOOR=none \
  -DCMAKE_CUDA_ARCHITECTURES="61;86"
cmake --build build-cuda12 --target strata -j "$JOBS"
ls -l build-cuda12/strata
