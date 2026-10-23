#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "COLMAP build failed at line $LINENO: $BASH_COMMAND" >&2' ERR
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || { echo 'Linux x86_64 required' >&2; exit 1; }
workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock="$workspace/engines/colmap-build.json"
read_lock() { node -p 'require(process.argv[1])[process.argv[2]]' "$lock" "$1"; }
cuda_root="${CUDA_PATH:-/usr/local/cuda-13.2}"
cpu_only="${OOOSPLAT_COLMAP_CPU:-0}"
# Prefer the selected toolkit even when called outside Actions.
[[ "$cpu_only" == 1 ]] || export PATH="$cuda_root/bin:$PATH"
prerequisites=(curl git tar cmake ninja node ldd patchelf)
[[ "$cpu_only" == 1 ]] || prerequisites+=(nvcc)
for command_name in "${prerequisites[@]}"; do
  command -v "$command_name" >/dev/null || { echo "Missing build prerequisite: $command_name" >&2; exit 1; }
done
check_version() {
  local component="$1" actual="$2" expected="$3"
  echo "$component: $actual (locked: $expected)"
  [[ "$actual" == "$expected" ]] || { echo "$component version differs from build lock: expected $expected, got $actual" >&2; exit 1; }
}
if [[ "$cpu_only" == 1 ]]; then
  # The lock pins the CI matrix; a local CPU build only records what it used.
  echo "CPU-only build: CMake $(cmake --version | head -1 | awk '{print $3}') / Ninja $(ninja --version) (lock: $(read_lock cmakeVersion) / $(read_lock ninjaVersion))"
else
  cmake_output="$(cmake --version)"
  check_version CMake "${cmake_output%%$'\n'*}" "cmake version $(read_lock cmakeVersion)"
  check_version Ninja "$(ninja --version)" "$(read_lock ninjaVersion)"
  node "$workspace/scripts/verify-cuda-toolkit.mjs" linux "$cuda_root"
fi
cache="$workspace/.cache/colmap-linux-build"
mkdir -p "$cache"
task_directory="$(mktemp -d "$cache/build-XXXXXX")"
commit="$(read_lock commit)"
archive="$cache/colmap-$commit.tar.gz"
if [[ ! -f "$archive" ]] || [[ "$(sha256sum "$archive" | awk '{print toupper($1)}')" != "$(read_lock sourceSha256)" ]]; then
  curl --fail --location --retry 3 "$(read_lock sourceUrl)" --output "$archive"
fi
echo "$(read_lock sourceSha256)  $archive" | sha256sum --check --status
tar -xzf "$archive" -C "$task_directory"
source="$task_directory/colmap-$commit"
vcpkg="$task_directory/vcpkg"
git clone --no-checkout https://github.com/microsoft/vcpkg.git "$vcpkg"
git -C "$vcpkg" checkout --detach "$(read_lock vcpkgCommit)"
bash "$vcpkg/bootstrap-vcpkg.sh" -disableMetrics
build="$task_directory/build"
stage="$task_directory/ooosplat-colmap-linux-x64"
options=()
while IFS= read -r feature; do options+=("-D${feature}_ENABLED=OFF"); done < <(node -e 'for(const f of require(process.argv[1]).disabledFeatures) console.log(f)' "$lock")
if [[ "$cpu_only" == 1 ]]; then
  # CPU-only shape: CPU SIFT, CPU matching, Ceres bundle adjustment, no Caspar.
  acceleration=(-DCUDA_ENABLED=OFF -DCASPAR_ENABLED=OFF)
else
  acceleration=(-DCUDA_ENABLED=ON -DCASPAR_ENABLED=ON
    -DCMAKE_CUDA_ARCHITECTURES:STRING="$(node -p 'require(process.argv[1]).cudaArchitectures.join(";")' "$lock")"
    -DCMAKE_CUDA_COMPILER:FILEPATH="$cuda_root/bin/nvcc"
    -DCUDAToolkit_ROOT:PATH="$cuda_root")
fi
cmake -S "$source" -B "$build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$stage" \
  -DGIT_COMMIT_ID="$commit" -DGIT_COMMIT_DATE=Unknown \
  -DCMAKE_TOOLCHAIN_FILE="$vcpkg/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_TARGET_TRIPLET=x64-linux-dynamic -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib' -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCASPAR_USE_DOUBLE=OFF "${acceleration[@]}" "${options[@]}"
[[ "$cpu_only" == 1 ]] || node "$workspace/scripts/verify-cuda-toolkit.mjs" linux "$cuda_root" "$build"
cmake --build "$build" --parallel "${OOOSPLAT_BUILD_JOBS:-4}"
cmake --install "$build"
installed="$build/vcpkg_installed/x64-linux-dynamic"
mkdir -p "$stage/lib"
# Preserve all release shared libraries and runtime-loaded plugins from the
# pinned core dependency tree, then collect their transitive ELF dependencies.
while IFS= read -r library; do
  relative="${library#"$installed/lib/"}"
  mkdir -p "$(dirname "$stage/lib/$relative")"
  cp -L "$library" "$stage/lib/$relative"
done < <(find -L "$installed/lib" -type f -name '*.so*' -print)
if [[ "$cpu_only" == 1 ]]; then
  node "$workspace/scripts/collect-linux-runtime.mjs" "$stage" "$installed"
else
  node "$workspace/scripts/collect-linux-runtime.mjs" "$stage" "$installed" "$cuda_root"
fi
while IFS= read -r library; do
  # NVIDIA redistributables must stay byte-for-byte unmodified.
  case "$(basename "$library")" in libcudart.so*|libcurand.so*) continue ;; esac
  relative_lib="$(realpath --relative-to="$(dirname "$library")" "$stage/lib")"
  patchelf --set-rpath "\$ORIGIN:\$ORIGIN/$relative_lib" "$library"
done < <(find "$stage/lib" -type f -name '*.so*')
patchelf --set-rpath '$ORIGIN/../lib' "$stage/bin/colmap"
if [[ "$cpu_only" == 1 ]]; then
  node "$workspace/scripts/package-colmap-cpu-runtime.mjs" linux "$stage" "$source" "$build" "$installed"
  runtime="$workspace/engines/linux/colmap"
  mkdir -p "$runtime"
  find "$runtime" -mindepth 1 -maxdepth 1 ! -name README.md -exec rm -rf {} +
  cp -a "$stage/." "$runtime/"
  echo "Installed CPU-only COLMAP into engines/linux/colmap"
  echo "Verify with: OOOSPLAT_COLMAP_CPU=1 bash scripts/verify-engines-linux.sh"
else
  curl --fail --location --retry 3 https://docs.nvidia.com/cuda/archive/13.2.0/eula/index.html --output "$stage/CUDA-EULA.html"
  node "$workspace/scripts/package-colmap-runtime.mjs" linux "$stage" "$source" "$build" "$installed"
fi
echo "Build retained for review: $task_directory"
