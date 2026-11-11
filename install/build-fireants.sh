#!/usr/bin/env bash
# build-fireants.sh — install FireANTs and its compiled CUDA extension into a conda
# environment, from the pinned FireANTs checkout.
#
#   install/build-fireants.sh --env-prefix DIR --src DIR
#
#   --env-prefix DIR  the conda environment (e.g. $VS_CONDA_ROOT/envs/$VS_HANDLER_ENV)
#   --src DIR         FireANTs checkout at the commit in versions.lock
#
# Two packages come out of the one checkout:
#   fireants            pure Python                      pip install --no-deps <src>
#   fireants_fused_ops  C++/CUDA extension (<src>/fused_ops), compiled HERE against
#                       the environment's torch. No index carries a wheel for it.
#
# What the compile needs, and where it comes from:
#   nvcc + CUDA headers   the environment itself (cuda-nvcc, cuda-cudart-dev,
#                         cuda-libraries-dev in envs/handler.yml). nvcc's release
#                         must equal torch.version.cuda; checked below.
#   host C++ compiler     CUDA 12.x accepts GCC <= 12; Ubuntu 24.04's default is 13.
#                         g++-12 is used when the default is too new
#                         (host prerequisite: apt install gcc-12 g++-12).
#   a visible GPU         not needed to compile. TORCH_CUDA_ARCH_LIST is taken from
#                         the GPU when one is visible, so the binary matches this box.
#
# Safe to re-run: both packages are reinstalled over themselves.
# Run it as the user that owns the environment.
set -euo pipefail
PREFIX=""; SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env-prefix) PREFIX="$2"; shift 2 ;;
    --src) SRC="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build-fireants: unknown argument: $1" >&2; exit 2 ;;
  esac
done
die() { printf 'build-fireants: %s\n' "$*" >&2; exit 1; }
[ -n "$PREFIX" ] && [ -n "$SRC" ] || die "--env-prefix and --src are required"
PY="$PREFIX/bin/python"
[ -x "$PY" ] || die "no python in $PREFIX (is the environment created?)"
[ -f "$SRC/fused_ops/pyproject.toml" ] || die "$SRC is not a FireANTs checkout (no fused_ops/)"

torch_cuda="$("$PY" -c 'import torch; print(torch.version.cuda or "")')" || die "torch is not importable in $PREFIX"
[ -n "$torch_cuda" ] || die "the torch in $PREFIX is a CPU build; the environment file must install a +cu wheel"
NVCC="$PREFIX/bin/nvcc"
[ -x "$NVCC" ] || die "no nvcc in $PREFIX/bin (cuda-nvcc missing from the environment file?)"
nvcc_rel="$("$NVCC" --version | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p')"
[ "$nvcc_rel" = "$torch_cuda" ] || die "nvcc is release $nvcc_rel but torch was built for CUDA $torch_cuda; they must match"

# Host compiler: CUDA 11 -> GCC <= 11, CUDA 12 -> GCC <= 12.
cuda_major="${torch_cuda%%.*}"
case "$cuda_major" in 11) max_gcc=11 ;; 12) max_gcc=12 ;; *) max_gcc=99 ;; esac
command -v gcc >/dev/null 2>&1 || die "no gcc on this host"
gcc_major="$(gcc -dumpversion | cut -d. -f1)"
unset NVCC_PREPEND_FLAGS NVCC_APPEND_FLAGS CUDAHOSTCXX
if [ "$gcc_major" -gt "$max_gcc" ]; then
  v="$max_gcc"; found=""
  while [ "$v" -ge 9 ]; do
    if command -v "gcc-$v" >/dev/null 2>&1 && command -v "g++-$v" >/dev/null 2>&1; then found="$v"; break; fi
    v=$((v - 1))
  done
  [ -n "$found" ] || die "host gcc is $gcc_major, too new for CUDA $torch_cuda (needs <= $max_gcc): sudo apt install gcc-$max_gcc g++-$max_gcc"
  export CC="gcc-$found" CXX="g++-$found" CUDAHOSTCXX="g++-$found"
  echo "build-fireants: host gcc $gcc_major is too new for CUDA $torch_cuda; using gcc-$found / g++-$found"
fi

export PATH="$PREFIX/bin:$PATH" CUDA_HOME="$PREFIX"
abi="$("$PY" -c 'import torch; print(int(torch.compiled_with_cxx11_abi()))')"
export CXXFLAGS="${CXXFLAGS:-} -D_GLIBCXX_USE_CXX11_ABI=$abi"
arch="$("$PY" -c '
import torch
caps = sorted({"%d.%d" % torch.cuda.get_device_capability(i) for i in range(torch.cuda.device_count())}) if torch.cuda.is_available() else []
print(";".join(caps))' 2>/dev/null || true)"
if [ -n "$arch" ]; then export TORCH_CUDA_ARCH_LIST="$arch"; fi
echo "build-fireants: torch CUDA $torch_cuda, nvcc $nvcc_rel, arch list '${TORCH_CUDA_ARCH_LIST:-torch default}', cxx11 abi $abi"

# --no-deps: every dependency is pinned in the environment file; nothing may drift in.
"$PY" -m pip install --no-deps --no-input "$SRC"
# --no-build-isolation: the build imports the environment's own torch.
"$PY" -m pip install --no-deps --no-input --no-build-isolation "$SRC/fused_ops"

"$PY" -c '
import torch, fireants, fireants_fused_ops
from importlib.metadata import version
print("build-fireants: ok — fireants", version("fireants"), "fireants_fused_ops", version("fireants_fused_ops"))'
