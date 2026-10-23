// Packages a CPU-only COLMAP build (-DCUDA_ENABLED=OFF -DCASPAR_ENABLED=OFF).
// The CUDA packager records NVIDIA terms and maps Ubuntu packages, neither of
// which exists here; this one inventories the vcpkg ports that actually shipped.
// Output shape matches the builder metadata verifyColmap() accepts.
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { buildLock, workspace, fileHash, filesUnder, verifyColmap } from "./colmap-runtime.mjs";

const [platform, stageArg, sourceArg, buildArg, installedArg] = process.argv.slice(2);
if (!["windows", "linux"].includes(platform)) throw new Error("Expected windows or linux");
const [stage, source, build, installed] = [stageArg, sourceArg, buildArg, installedArg].map(p => path.resolve(p));
if (!stage.startsWith(`${path.join(workspace, ".cache", `colmap-${platform}-build`)}${path.sep}`)) throw new Error("Unsafe staging directory");

const cacheText = fs.readFileSync(path.join(build, "CMakeCache.txt"), "utf8");
for (const feature of [...buildLock.disabledFeatures, "CUDA", "CASPAR"]) {
  if (!cacheText.includes(`${feature}_ENABLED:BOOL=OFF`)) throw new Error(`CPU packaging requires ${feature}=OFF in the actual build`);
}
if (!cacheText.includes("CASPAR_USE_DOUBLE:BOOL=OFF")) throw new Error("Actual build must use Caspar f32");

for (const directory of ["include", "share", "lib/cmake", "lib/pkgconfig"]) fs.rmSync(path.join(stage, directory), { recursive: true, force: true });
for (const file of filesUnder(stage)) if (/(?:_test\.exe|\.pdb|\.a|\.lib)$/i.test(file)) fs.unlinkSync(file);

const licenseRoot = path.join(stage, "licenses");
const copyLicense = (file, relative) => {
  fs.mkdirSync(path.dirname(path.join(licenseRoot, relative)), { recursive: true });
  fs.copyFileSync(file, path.join(licenseRoot, relative));
};
copyLicense(path.join(source, "COPYING.txt"), "COLMAP-LICENSE.txt");
for (const component of ["PoissonRecon", "SiftGPU", "VLFeat"]) {
  const license = path.join(source, "src/thirdparty", component, "LICENSE");
  if (fs.existsSync(license)) copyLicense(license, `colmap-thirdparty/${component}-LICENSE.txt`);
}

// Attribute every shipped shared library to the vcpkg port that installed it.
const owners = new Map();
const components = new Map();
const triplet = path.basename(installed);
const infoRoot = path.join(path.dirname(installed), "vcpkg/info");
// Libraries may resolve from any triplet dir (OpenImageIO pulls zlib-ng from the
// static x64-linux triplet), so attribute across every vcpkg list, preferring the
// build triplet when a port exists in both.
const listFiles = fs.readdirSync(infoRoot).filter(name => name.endsWith(".list"));
listFiles.sort((a, b) => Number(b.endsWith(`_${triplet}.list`)) - Number(a.endsWith(`_${triplet}.list`)));
for (const list of listFiles) {
  const port = list.slice(0, list.lastIndexOf("_"));
  const copyright = path.join(installed, "share", port, "copyright");
  const component = { name: port, licenseFiles: [], runtimeFiles: [] };
  if (fs.existsSync(copyright)) {
    copyLicense(copyright, `vcpkg/${port}/copyright`);
    component.licenseFiles.push(`vcpkg/${port}/copyright`);
  }
  for (const relative of fs.readFileSync(path.join(infoRoot, list), "utf8").split(/\r?\n/).filter(Boolean)) {
    const base = path.basename(relative);
    if (/\.(?:so|dll)(?:\.|$)/i.test(base)) owners.set(base.toLowerCase(), component);
  }
  if (component.licenseFiles.length) components.set(port, component);
}
const colmapComponent = { name: "COLMAP", licenseFiles: ["COLMAP-LICENSE.txt"], runtimeFiles: ["bin/colmap"] };
for (const file of filesUnder(stage).filter(name => /\.(?:so|dll)(?:\.|$)/i.test(path.basename(name)))) {
  const relative = path.relative(stage, file).split(path.sep).join("/");
  const owner = owners.get(path.basename(file).toLowerCase());
  if (!owner) throw new Error(`Cannot attribute runtime library ${relative} to a vcpkg port`);
  owner.runtimeFiles.push(relative);
}
const inventory = {
  schemaVersion: 1,
  note: "CPU-only local build: pinned vcpkg ports plus every shipped runtime library.",
  components: [colmapComponent, ...[...components.values()].filter(c => c.runtimeFiles.length)],
  sourceLicenseFiles: filesUnder(licenseRoot).map(file => path.relative(licenseRoot, file).split(path.sep).join("/")),
};
fs.writeFileSync(path.join(stage, "BUNDLED-COMPONENTS.json"), JSON.stringify(inventory, null, 2) + "\n");

const colmapFeatures = Object.fromEntries(buildLock.disabledFeatures.map(feature => [feature, false]));
Object.assign(colmapFeatures, { CUDA: false, CASPAR: false, CERES: true, CASPAR_USE_DOUBLE: false });
const compiler = spawnSync("c++", ["--version"], { encoding: "utf8" });
const info = {
  schemaVersion: 1, platform, architecture: "x64", cpuOnly: true, generatedAt: new Date().toISOString(),
  colmap: { version: buildLock.version, commit: buildLock.commit, sourceUrl: buildLock.sourceUrl, sourceSha256: buildLock.sourceSha256 },
  colmapFeatures,
  dependencies: { vcpkgCommit: buildLock.vcpkgCommit },
  toolchain: { cmake: spawnSync("cmake", ["--version"], { encoding: "utf8" }).stdout?.split("\n")[0]?.trim(), ninja: spawnSync("ninja", ["--version"], { encoding: "utf8" }).stdout?.trim(), compiler: `${compiler.stdout ?? ""}${compiler.stderr ?? ""}`.trim() },
  trimPolicy: buildLock.trimPolicy,
};
fs.writeFileSync(path.join(stage, "BUILD-INFO.json"), JSON.stringify(info, null, 2) + "\n");
const entries = filesUnder(stage).filter(file => path.basename(file) !== "SHA256SUMS").map(file => `${fileHash(file)}  ${path.relative(stage, file).split(path.sep).join("/")}`);
fs.writeFileSync(path.join(stage, "SHA256SUMS"), entries.join("\n") + "\n");
verifyColmap(stage, platform, fileHash(path.join(stage, "SHA256SUMS")));
const smoke = spawnSync(process.execPath, [path.join(workspace, "scripts/smoke-colmap-image-io.mjs"), path.join(stage, "bin/colmap")], { stdio: "inherit", windowsHide: true });
if (smoke.error || smoke.status !== 0) throw new Error("CPU-only runtime failed JPEG/PNG/CPU SIFT smoke verification");
console.log(JSON.stringify({ stage, cpuOnly: true, features: colmapFeatures, integritySha256: fileHash(path.join(stage, "SHA256SUMS")),
  runtimeBytes: filesUnder(stage).reduce((sum, file) => sum + fs.statSync(file).size, 0) }, null, 2));
