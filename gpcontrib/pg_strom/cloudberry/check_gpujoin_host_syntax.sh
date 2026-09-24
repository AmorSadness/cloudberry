#!/usr/bin/env bash
# C/API syntax only. Opaque CUDA declarations are NOT a CUDA SDK/build.
set -euo pipefail
source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../src" && pwd)
pg_config=${PG_CONFIG:-pg_config}
work=$(mktemp -d /tmp/pgstrom-join-syntax.XXXXXX)
trap 'rm -rf "$work"' EXIT
cat > "$work/cuda.h" <<'EOF'
#ifndef CUDA_H
#define CUDA_H
typedef int CUresult;
typedef unsigned long long CUdeviceptr;
typedef void *CUfunction;
typedef void *CUcontext;
typedef void *CUstream;
typedef struct { char bytes[16]; } CUuuid;
#endif
EOF
: > "$work/cufile.h"
: > "$work/gpu_devattrs.h"
"${CC:-cc}" -fsyntax-only -D_GNU_SOURCE -D__PGSTROM_MODULE__=1 -D__STROM_HOST__=1 \
    -DCUDA_MAXTHREADS_PER_BLOCK=1024 '-DPGSTROM_VERSION="6.1"' \
    -I"$work" -I"$("$pg_config" --includedir-server)" \
    -I"$("$pg_config" --includedir)/internal" -I"$source_dir" \
    -Werror=implicit-function-declaration -Werror=incompatible-pointer-types \
    "$source_dir/gpu_join.c" "$source_dir/gpu_scan.c" \
    "$source_dir/executor.c" "$source_dir/main.c"
printf '%s\n' 'GpuJoin host C/API syntax: PASS (opaque CUDA declarations; no SDK, link or device build)'
