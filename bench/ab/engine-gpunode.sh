#!/bin/sh
# The stock engine with every allocation preferring the GPU's NUMA node (0 on this box: /sys/.../03:00.0/numa_node).
# MPOL_PREFERRED, not BIND: it falls back to the other node instead of making the kernel reclaim inside node 0, and
# the arena (33 GiB) is allocated and loaded first, so it is the allocation that gets the node.
exec numactl --preferred=0 /home/almir/models-ssd/Strata/engine-cuda12/strata "$@"
