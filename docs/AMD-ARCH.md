# AMD / Arch Linux 无 CUDA 运行记录

日期：2026-10-23，Asia/Shanghai。

结论：本机（Arch Linux、Ryzen 9 5950X、Radeon RX 7900 GRE、无 NVIDIA、无 CUDA Toolkit）可以完整跑通
COLMAP 稀疏重建 + OOOBrush 训练导出。改动只有引擎校验脚本与一个本地 CPU 构建路径，
应用本体（Rust/TS）未改：它本来就按 `nvidia-smi` 结果回退到 CPU SIFT 与 Ceres。

## 硬件与驱动

- GPU：AMD Radeon RX 7900 GRE（gfx1100，16 GB），RADV 驱动 `Mesa 26.2.5-arch1.1`。
- Vulkan 实例版本 1.4.363（`vulkaninfo`）。
- 无 `nvidia-smi`、无 `nvcc`、无 `/usr/local/cuda-*`。

## 应用为什么不改也能跑

- `src-tauri/src/engines/health.rs` 的加速探测只看 NVIDIA（`nvidia-smi`），本机返回
  `ColmapBackend::Cpu`，因此 `ColmapAccelerationStatus::gpu_index()` 返回 `None`。
- `src-tauri/src/engines/colmap.rs` 在 `gpu_index` 为 `None` 时传
  `--FeatureExtraction.use_gpu 0` / `--FeatureMatching.use_gpu 0`。
- `src-tauri/src/engines/colmap_ba.rs:41-43` 的 `select()` 在
  `compatible_gpu.filter(|_| !cfg!(target_os = "macos"))` 为 `None` 时直接返回 Ceres
  后端，所以本机不会尝试 Caspar 的 GPU BA。

Brush 的后端同样不由应用指定：`src-tauri/src/engines/brush.rs:396-397` 的测试断言进程环境里
不存在 `WGPU_BACKEND`，Linux 上 wgpu 只提供 Vulkan/GL 两个后端（DX12 仅 Windows），
实测自动选中 Vulkan（见下）。

即：AMD 机器天然走 CPU 路径，前提是 COLMAP 二进制能通过校验。

## 已发布 Linux 运行时本身就带 CPU 路径

`engines/manifest.linux.json` 固定的 `colmap-4.2.1-runtime.1-linux-x64` 是 CUDA 构建，
但它的发布验收记录（同 Release 的 `.manifest.json`）里写的是
`cudaVisibleDevices: "-1"` 与 `cpu-sift`/`cpu-matching`/`cpu-sparse-reconstruction`/
`ceres-cpu-ba`/`cpu-loop-detection`。实测在本机（无 NVIDIA 驱动）可直接运行：

```bash
npm run setup:engines:linux     # 下载并校验固定运行时 + OOOBrush
engines/linux/colmap/bin/colmap feature_extractor -h   # 正常输出，含 "with CUDA" 标记
```

CUDA 只影响 GPU 分支；CPU 分支不需要驱动。

## 改动清单

1. `scripts/colmap-runtime.mjs`
   - 新增 `cpuOnlyAllowed()`（`OOOSPLAT_COLMAP_CPU=1`）与 `cudaRequired(platform)`。
   - `verifyReleaseMetadata()` / `verifyBuilderMetadata()`：CUDA 从"平台硬性要求"变成
     "默认要求、可在 CPU 开关下放宽"；Caspar 必须跟随 CUDA；CPU 构建不得声明
     `cudaRelease`/`gpuArchitectures`。
   - `verifyColmap()`：`with cuda` 与 `--BundleAdjustmentCaspar.gpu_index` 的断言改为
     与运行时自身 `BUILD-INFO` 声明一致（原来按平台硬编码，macOS 之所以能过的原因就是
     它走了特例）。
   - 空 pin + CPU 开关时，用运行时自己的 `SHA256SUMS` 作 pin（本地 CPU 构建没有发布归档可
     pin，但每个文件仍要进清单）。
2. `scripts/setup-colmap-runtime.mjs`：CPU 开关打开时不下载 CUDA 归档，改为校验
   `engines/linux/colmap` 里的本地 CPU 构建，缺失时给出构建命令。
3. `scripts/verify-engines-linux.sh`：CPU 开关打开时跳过 release pin，并如实打印
   "CPU-only COLMAP (Ceres bundle adjustment, no CUDA)"。
4. `scripts/build-colmap-linux.sh`：`OOOSPLAT_COLMAP_CPU=1` 时不再要求 `nvcc`/CUDA
   工具链，不校验 CUDA 工具链与 CMake/Ninja 版本钉（记录实际版本），配置参数改为
   `-DCUDA_ENABLED=OFF -DCASPAR_ENABLED=OFF`，跳过 NVIDIA EULA 抓取，产物用
   `package-colmap-cpu-runtime.mjs` 打包并安装到 `engines/linux/colmap`。
5. `scripts/package-colmap-cpu-runtime.mjs`（新增）：生成 builder 形态的 `BUILD-INFO.json`、
   `BUNDLED-COMPONENTS.json`、`SHA256SUMS` 并自校验。原 CUDA 打包器绑定 NVIDIA 条款与
   `dpkg-query`，在 Arch 上不可用。
6. `scripts/collect-linux-runtime.mjs`：CUDA 根目录改为可选参数（CPU 构建没有它）。
7. `scripts/fixtures/synthetic-scene.py`（新增）：Blender 无头渲染 24 视角合成场景，
   给没有图片 fixture 的仓库提供可复现的端到端样本；输出落在 `.cache/amd-arch/images`。
8. 测试：`scripts/colmap-runtime.test.mjs` 增加 CPU 开关与自有 pin 两条用例；
   `scripts/colmap-development.test.mjs` 增加 CPU 预检用例（CMake/Ninja 版本漂移不再拦）。

默认行为不变：不设 `OOOSPLAT_COLMAP_CPU` 时仍要求 CUDA 运行时与 release pin。

## 运行方式

```bash
# 1. 引擎（固定运行时，CPU 模式运行；这是默认路径）
npm run setup:engines:linux
npm run verify:engines:linux

# 2. 可选：真正不带 CUDA 的本地 COLMAP（vcpkg 全量构建，耗时较长）
OOOSPLAT_COLMAP_CPU=1 OOOSPLAT_BUILD_JOBS=28 bash scripts/build-colmap-linux.sh
OOOSPLAT_COLMAP_CPU=1 bash scripts/verify-engines-linux.sh

# 3. 端到端样本（合成 24 视角）
blender --background --python scripts/fixtures/synthetic-scene.py -- .cache/amd-arch/images 24
```

### 本地 CPU 构建在本机的实测状态

`OOOSPLAT_COLMAP_CPU=1 bash scripts/build-colmap-linux.sh` 在本机跑到 vcpkg 依赖阶段后停住，
两个原因都与本次改动无关，属于环境缺件：

1. `lapack-reference`（ceres 的 `lapack` 特性）构建失败：
   `CMake Error at scripts/cmake/vcpkg_find_fortran.cmake:65` —— 本机没有 `gfortran`。
   需要装 `gcc-fortran`（系统包，超出本仓库范围）。
2. vcpkg 拉 distfile 时偶发 `error: curl operation failed with error code 35 (SSL connect error)`，
   走本机 HTTP 代理（`http_proxy=http://127.0.0.1:7897`）时按端口随机出现；重试能逐个推进
   （已构建 88 个端口），但每次都要重新解析依赖。

脚本层面的 CPU 分支本身是通的：预检打印
`CPU-only build: CMake 4.4.4 / Ninja 1.13.2 (lock: 4.3.2 / 1.12.1)`，
传给 CMake 的配置确实是 `-DCUDA_ENABLED=OFF -DCASPAR_ENABLED=OFF` 与全部
`disabledFeatures`，只是依赖没装完。装好 `gcc-fortran` 后重跑同一条命令即可继续。

## 端到端验收（本机实测）

重建（CPU SIFT + CPU 匹配 + Ceres BA）：

```bash
COLMAP=engines/linux/colmap/bin/colmap
$COLMAP feature_extractor --database_path recon/db.db --image_path images \
  --ImageReader.single_camera 1 --FeatureExtraction.use_gpu 0 --FeatureExtraction.num_threads 16
$COLMAP exhaustive_matcher --database_path recon/db.db --FeatureMatching.use_gpu 0
$COLMAP mapper --database_path recon/db.db --image_path images --output_path recon/sparse
$COLMAP model_analyzer --path recon/sparse/0
```

结果：24 张 640×480 输入，每张 1411–1465 个 CPU SIFT 特征；
`Images: 19`、`Points: 1674`、`Observations: 6311`、`Mean reprojection error: 0.203058px`。

训练（Brush，wgpu/Vulkan）：

```bash
engines/linux/brush/brush_app --total-train-iters 300 --max-resolution 320 \
  --refine-every 100 --max-splats 30000 --growth-stop-iter 300 \
  --export-every 300 --export-path "$PWD/brush-out" --export-name final.ply dataset
```

结果：`GPU initialization completed ... backend=Vulkan device=AMD Radeon RX 7900 GRE (RADV NAVI31)`，
`iteration=300 total=300 elapsed_secs=7.638`，导出 `final.ply`（2616 个 splat，605 KB）。

仓库自带校验：

```bash
npm run test:brush:gpu        # backend=Vulkan, "gpuExecutionValidated": true
npm run test:engine-scripts   # 77 tests, 0 fail
npm run verify:colmap-lock
node scripts/smoke-colmap-image-io.mjs engines/linux/colmap/bin/colmap
```

`test:brush:gpu` 的硬件行：
`backend=Vulkan device=AMD Radeon RX 7900 GRE (RADV NAVI31) type=DiscreteGpu driver=radv`。
Linux 上 wgpu 只有 Vulkan/GL 两个后端，DX12 不存在，无需额外开关；日志里
`Compute backend: Device<Cube(Wgpu(WgpuDevice { kind: DefaultDevice, backend: Auto }))>`
即自动挑选到了 Vulkan。

## 仍不支持

- **稠密 MVS**：`patch_match_stereo`/`stereo_fusion` 需要 CUDA，且 `engines/colmap-build.json`
  的 `disabledFeatures` 已含 `MVS`。应用当前只调用稀疏流程
  （`feature_extractor`、`sequential_matcher`、`exhaustive_matcher`、`matches_importer`、
  `mapper`、`bundle_adjuster`），所以不影响现有功能；将来做稠密重建需要另找 CUDA 或 OpenMVS 路径。
- **CUDA SIFT / Caspar GPU 全局 BA**：无 NVIDIA 卡，永远走 CPU SIFT 与 Ceres。
- **ONNX / 神经网络特征**：构建时关闭。
- **发行版 COLMAP 直接替换**：`scripts/verify-colmap-lock.mjs` 仍禁止把系统 COLMAP 写进
  Linux 清单（清单钉的是固定 Release）；本地 CPU 构建只在 `OOOSPLAT_COLMAP_CPU=1` 下认可。
- CPU 与 GPU 的速度差：本样本 24 张固定视角下 CPU SIFT + 匹配合计约 1.2 秒，真实数据集
  （数百张手机照片）会慢一到两个数量级，这是 CPU 路径的固有成本，不是配置问题。

## 相关文件

- `engines/manifest.linux.json`：Linux 固定运行时（未改）。
- `engines/colmap-runtime.json`、`engines/colmap-build.json`：release/build 锁（未改）。
- `scripts/colmap-runtime.mjs`、`scripts/setup-colmap-runtime.mjs`、
  `scripts/verify-engines-linux.sh`、`scripts/build-colmap-linux.sh`、
  `scripts/package-colmap-cpu-runtime.mjs`、`scripts/collect-linux-runtime.mjs`、
  `scripts/fixtures/synthetic-scene.py`。
