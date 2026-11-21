#!/usr/bin/env node
"use strict";

// src/cli.ts
var import_node_util = require("util");
var import_node_fs11 = require("fs");

// src/api.ts
var import_node_zlib = require("zlib");
var DEFAULT_URL = "https://api.zharp.io";
var UploadError = class extends Error {
  constructor(message, status, permanent = false) {
    super(message);
    this.status = status;
    this.permanent = permanent;
    this.name = "UploadError";
  }
  status;
  permanent;
};
function resolveConnection(options) {
  const authToken = options.authToken || process.env.ZHARP_AUTH_TOKEN;
  const app = options.app ?? process.env.ZHARP_APP;
  const missing = [];
  if (!authToken) missing.push('an auth token (ZHARP_AUTH_TOKEN, or the authToken option): a workspace API key with the "artifacts:write" scope');
  if (app === void 0 || app === "") missing.push("the application ID (--app, the app option, or ZHARP_APP)");
  if (missing.length) throw new UploadError(`Cannot upload without ${missing.join(" and ")}.`, void 0, true);
  return { url: (options.url || process.env.ZHARP_URL || DEFAULT_URL).replace(/\/+$/, ""), authToken, app };
}
function artifactsUrl(connection) {
  return `${connection.url}/api/v1/applications/${encodeURIComponent(String(connection.app))}/artifacts`;
}
var sleep = (ms) => new Promise((resolve6) => setTimeout(resolve6, ms));
async function uploadArtifact(connection, artifact, options = {}) {
  const doFetch = options.fetch ?? fetch;
  const retries = options.retries ?? 3;
  const backoff = options.backoffMs ?? 1e3;
  const fileName = (artifact.name.split("/").pop() || "artifact") + (artifact.gzip ? ".gz" : "");
  const payload = artifact.gzip ? (0, import_node_zlib.gzipSync)(artifact.data) : artifact.data;
  for (let attempt = 0; ; attempt++) {
    const form = new FormData();
    form.set("kind", artifact.kind);
    form.set("debugId", artifact.debugId);
    form.set("name", artifact.name);
    if (artifact.release) form.set("release", artifact.release);
    if (artifact.arch) form.set("arch", artifact.arch);
    const type = artifact.gzip ? "application/gzip" : artifact.kind === "sourcemap" ? "application/json" : "application/octet-stream";
    form.set("file", new Blob([payload], { type }), fileName);
    let retryAfter = 0;
    let error;
    try {
      const response = await doFetch(artifactsUrl(connection), {
        method: "POST",
        headers: { Authorization: `Bearer ${connection.authToken}`, "User-Agent": "zharp-cli" },
        body: form
      });
      const text = await response.text().catch(() => "");
      if (response.ok) {
        try {
          return text ? JSON.parse(text) : null;
        } catch {
          return text;
        }
      }
      error = describeFailure(response.status, text, connection);
      retryAfter = Number(response.headers.get("retry-after")) * 1e3 || 0;
    } catch (cause) {
      error = new UploadError(`Could not reach ${connection.url}: ${cause?.message ?? cause}`);
    }
    if (error.permanent || attempt >= retries) throw error;
    await sleep(Math.max(retryAfter, backoff * 2 ** attempt));
  }
}
function serverMessage(text) {
  try {
    const body = JSON.parse(text);
    const message = body?.message ?? body?.error;
    if (typeof message === "string") return message;
    if (Array.isArray(message)) return message.join("; ");
  } catch {
  }
  return text.slice(0, 300);
}
function describeFailure(status, text, connection) {
  const detail = serverMessage(text);
  const retryable = status === 408 || status === 429 || status >= 500;
  const explain = {
    401: "The auth token was rejected \u2014 check ZHARP_AUTH_TOKEN (a workspace API key, not the app key).",
    403: 'The API key cannot upload here \u2014 it needs the "artifacts:write" scope, in the workspace that owns the app.',
    404: `Application ${connection.app} was not found \u2014 check --app (the ID in the app's dashboard URL) and ZHARP_URL.`,
    413: "The file is larger than the server accepts."
  };
  const message = `${explain[status] ?? `Upload failed with HTTP ${status}.`}${detail ? ` Server said: ${detail}` : ""}`;
  return new UploadError(message, status, !retryable);
}
async function eachLimit(items, limit, fn) {
  let next = 0;
  let failed;
  const worker = async () => {
    while (failed === void 0 && next < items.length) {
      const index = next++;
      try {
        await fn(items[index], index);
      } catch (error) {
        failed ??= error;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  if (failed !== void 0) throw failed;
}

// src/log.ts
var consoleLogger = (prefix = "[zharp]") => ({
  info: (message) => console.log(`${prefix} ${message}`),
  warn: (message) => console.warn(`${prefix} ${message}`)
});

// src/native.ts
var import_node_fs4 = require("fs");
var import_node_path3 = require("path");

// src/elf.ts
var NT_GNU_BUILD_ID = 3;
var SHT_NOTE = 7;
var PT_NOTE = 4;
var MACHINES = { 3: "x86", 40: "arm", 62: "x86_64", 183: "arm64", 243: "riscv64" };
function isElf(data) {
  return data.length >= 16 && data[0] === 127 && data[1] === 69 && data[2] === 76 && data[3] === 70;
}
function readElf(data) {
  if (!isElf(data)) throw new Error("not an ELF file");
  const bits = data[4] === 2 ? 64 : 32;
  const littleEndian = data[5] !== 2;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const u16 = (o) => view.getUint16(o, littleEndian);
  const u32 = (o) => view.getUint32(o, littleEndian);
  const addr = (o) => bits === 64 ? Number(view.getBigUint64(o, littleEndian)) : u32(o);
  const info = { bits, littleEndian, arch: MACHINES[u16(18)] };
  const notes = (offset, size) => {
    let p = offset;
    const end = Math.min(offset + size, data.length);
    while (p + 12 <= end) {
      const nameSize = u32(p);
      const descSize = u32(p + 4);
      const type = u32(p + 8);
      const nameStart = p + 12;
      const descStart = nameStart + align4(nameSize);
      if (descStart + descSize > end) break;
      const name = String.fromCharCode(...data.subarray(nameStart, nameStart + Math.max(0, nameSize - 1)));
      if (name === "GNU" && type === NT_GNU_BUILD_ID) return hex(data.subarray(descStart, descStart + descSize));
      p = descStart + align4(descSize);
    }
    return void 0;
  };
  const shoff = addr(bits === 64 ? 40 : 32);
  const shentsize = u16(bits === 64 ? 58 : 46);
  const shnum = u16(bits === 64 ? 60 : 48);
  for (let i = 0; i < shnum && shoff > 0; i++) {
    const h = shoff + i * shentsize;
    if (h + shentsize > data.length) break;
    if (u32(h + 4) !== SHT_NOTE) continue;
    const offset = addr(bits === 64 ? h + 24 : h + 16);
    const size = addr(bits === 64 ? h + 32 : h + 20);
    const id = notes(offset, size);
    if (id) return { ...info, buildId: id };
  }
  const phoff = addr(bits === 64 ? 32 : 28);
  const phentsize = u16(bits === 64 ? 54 : 42);
  const phnum = u16(bits === 64 ? 56 : 44);
  for (let i = 0; i < phnum && phoff > 0; i++) {
    const h = phoff + i * phentsize;
    if (h + phentsize > data.length) break;
    if (u32(h) !== PT_NOTE) continue;
    const offset = addr(bits === 64 ? h + 8 : h + 4);
    const size = addr(bits === 64 ? h + 32 : h + 16);
    const id = notes(offset, size);
    if (id) return { ...info, buildId: id };
  }
  return info;
}
var align4 = (n) => n + 3 & ~3;
function hex(bytes) {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

// src/files.ts
var import_node_fs = require("fs");
var import_node_path = require("path");
function walk(dir) {
  const out = [];
  const visit = (current) => {
    for (const entry of (0, import_node_fs.readdirSync)(current, { withFileTypes: true })) {
      const full = (0, import_node_path.join)(current, entry.name);
      if (entry.isDirectory()) {
        if (entry.name !== "node_modules") visit(full);
      } else if (entry.isFile()) out.push(full);
      else if (entry.isSymbolicLink()) {
        try {
          if ((0, import_node_fs.statSync)(full).isFile()) out.push(full);
        } catch {
        }
      }
    }
  };
  visit(dir);
  return out.sort();
}
function relativePath(dir, path) {
  return (0, import_node_path.relative)(dir, path).split(import_node_path.sep).join("/");
}
function globToRegExp(glob) {
  let out = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        const slash = glob[i + 2] === "/";
        out += slash ? "(?:.*/)?" : ".*";
        i += slash ? 2 : 1;
      } else out += "[^/]*";
    } else if (c === "?") out += "[^/]";
    else out += /[.+^${}()|[\]\\]/.test(c) ? `\\${c}` : c;
  }
  return new RegExp(glob.includes("/") ? `^${out}$` : `(?:^|/)${out}$`);
}
function toList(pattern) {
  if (pattern === void 0) return [];
  return (Array.isArray(pattern) ? pattern : [pattern]).map((p) => typeof p === "string" ? globToRegExp(p) : p);
}
function pathFilter(include, exclude) {
  const inc = toList(include);
  const exc = toList(exclude);
  return (path) => (inc.length === 0 || inc.some((r) => r.test(path))) && !exc.some((r) => r.test(path));
}
function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} kB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

// src/macho.ts
var LC_UUID = 27;
var MH_MAGIC = 4277009102;
var MH_MAGIC_64 = 4277009103;
var FAT_MAGIC = 3405691582;
var FAT_MAGIC_64 = 3405691583;
function isMachO(data) {
  if (data.length < 8) return false;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const be = view.getUint32(0, false);
  const le = view.getUint32(0, true);
  return be === FAT_MAGIC || be === FAT_MAGIC_64 || [MH_MAGIC, MH_MAGIC_64].includes(le) || [MH_MAGIC, MH_MAGIC_64].includes(be);
}
function archName(cpuType, cpuSubtype) {
  const sub = cpuSubtype & 16777215;
  switch (cpuType) {
    case 16777228:
      return sub === 2 ? "arm64e" : "arm64";
    case 33554444:
      return "arm64_32";
    case 12:
      return sub === 9 ? "armv7" : sub === 11 ? "armv7s" : sub === 12 ? "armv7k" : "arm";
    case 16777223:
      return sub === 8 ? "x86_64h" : "x86_64";
    case 7:
      return "i386";
    default:
      return `cpu${cpuType}`;
  }
}
function readMachO(data) {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const magic = view.getUint32(0, false);
  if (magic === FAT_MAGIC || magic === FAT_MAGIC_64) {
    const wide = magic === FAT_MAGIC_64;
    const count = view.getUint32(4, false);
    const images = [];
    for (let i = 0; i < count; i++) {
      const h = 8 + i * (wide ? 32 : 20);
      const offset = wide ? Number(view.getBigUint64(h + 8, false)) : view.getUint32(h + 8, false);
      const size = wide ? Number(view.getBigUint64(h + 16, false)) : view.getUint32(h + 12, false);
      images.push(...readThin(data.subarray(offset, offset + size)).map((image) => ({ ...image, offset })));
    }
    return images;
  }
  return readThin(data);
}
function readThin(data) {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  let little;
  if ([MH_MAGIC, MH_MAGIC_64].includes(view.getUint32(0, true))) little = true;
  else if ([MH_MAGIC, MH_MAGIC_64].includes(view.getUint32(0, false))) little = false;
  else throw new Error("not a Mach-O file");
  const wide = view.getUint32(0, little) === MH_MAGIC_64;
  const cpuType = view.getUint32(4, little);
  const cpuSubtype = view.getUint32(8, little);
  const ncmds = view.getUint32(16, little);
  let p = wide ? 32 : 28;
  for (let i = 0; i < ncmds && p + 8 <= data.length; i++) {
    const cmd = view.getUint32(p, little);
    const size = view.getUint32(p + 4, little);
    if (cmd === LC_UUID && p + 24 <= data.length) {
      return [{ uuid: formatUuid(data.subarray(p + 8, p + 24)), arch: archName(cpuType, cpuSubtype), offset: 0, size: data.length }];
    }
    if (size < 8) break;
    p += size;
  }
  return [];
}
function formatUuid(bytes) {
  let hex2 = "";
  for (const b of bytes) hex2 += b.toString(16).padStart(2, "0");
  hex2 = hex2.toUpperCase();
  return `${hex2.slice(0, 8)}-${hex2.slice(8, 12)}-${hex2.slice(12, 16)}-${hex2.slice(16, 20)}-${hex2.slice(20)}`;
}

// src/swift-names.ts
var import_node_child_process = require("child_process");
var import_node_fs2 = require("fs");
var xcrun = (tool, args, input) => {
  const result = (0, import_node_child_process.spawnSync)("xcrun", [tool, ...args], { input, encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });
  return result.status === 0 && typeof result.stdout === "string" ? result.stdout : null;
};
var SWIFT = /\$s[0-9A-Za-z_$]{3,}/g;
var NOT_CODE = /^(type metadata(?! accessor)|full type metadata|(nominal type|protocol|protocol conformance|associated (type|conformance)|method|property|module|extension|anonymous|reflection metadata|opaque type) descriptor|reflection metadata|protocol (requirements base|witness table)(?! accessor)|value witness table|field offset|enum case for|lazy cache variable|demangling cache variable|flag for loading|metaclass for|class metadata base offset|objc metaclass|type metadata (pattern|completion|instantiation cache)|generic (type|protocol witness table) (instantiation cache|pattern))/;
function mangledNamesIn(data) {
  return new Set(data.toString("latin1").match(SWIFT) ?? []);
}
function swiftNames(files, tool = process.platform === "darwin" ? xcrun : null, read4 = import_node_fs2.readFileSync) {
  if (!tool) return null;
  const symbols = /* @__PURE__ */ new Set();
  for (const file of new Set(files)) {
    for (const name of mangledNamesIn(read4(file))) symbols.add(name);
  }
  if (!symbols.size) return {};
  const mangled = [...symbols];
  const decoded = tool("swift-demangle", ["--simplified", "--compact"], `${mangled.join("\n")}
`);
  if (decoded === null) return null;
  const lines = decoded.split("\n");
  const out = {};
  mangled.forEach((name, i) => {
    const readable = lines[i]?.trim();
    if (readable && readable !== name && !NOT_CODE.test(readable)) out[name] = readable;
  });
  return out;
}

// src/source-bundle.ts
var import_node_fs3 = require("fs");
var import_node_path2 = require("path");
var SKIP_DIRS = /* @__PURE__ */ new Set([
  "node_modules",
  ".git",
  ".svn",
  ".hg",
  "build",
  ".build",
  ".dart_tool",
  ".pub-cache",
  ".gradle",
  ".idea",
  ".vscode",
  "test",
  "integration_test",
  "Pods",
  "Carthage",
  "DerivedData",
  "xcuserdata",
  ".swiftpm",
  "SourcePackages",
  "vendor",
  ".fvm",
  ".symlinks",
  "ephemeral"
]);
var MAX_FILE_BYTES = 1024 * 1024;
var MAX_TOTAL_BYTES = 50 * 1024 * 1024;
var MAX_FILES = 2e4;
function collectSources(root, extensions, skipDirs = []) {
  const skip = /* @__PURE__ */ new Set([...SKIP_DIRS, ...skipDirs]);
  const wanted = new Set(extensions.map((e) => e.toLowerCase()));
  const out = { root, files: {}, count: 0, bytes: 0, skipped: 0 };
  const visit = (dir) => {
    let entries;
    try {
      entries = (0, import_node_fs3.readdirSync)(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const full = (0, import_node_path2.join)(dir, entry.name);
      if (entry.isDirectory()) {
        if (!skip.has(entry.name) && !/\.(xcassets|dSYM)$|Tests$/.test(entry.name)) visit(full);
        continue;
      }
      if (!entry.isFile()) continue;
      const dot = entry.name.lastIndexOf(".");
      if (dot < 0 || !wanted.has(entry.name.slice(dot).toLowerCase())) continue;
      const size = (0, import_node_fs3.statSync)(full).size;
      if (size > MAX_FILE_BYTES || out.bytes + size > MAX_TOTAL_BYTES || out.count >= MAX_FILES) {
        out.skipped += 1;
        continue;
      }
      out.files[relativePath(root, full)] = (0, import_node_fs3.readFileSync)(full, "utf8");
      out.count += 1;
      out.bytes += size;
    }
  };
  visit(root);
  return out;
}
function sourceBundleArtifacts(sources, buildIds, release2) {
  if (!sources.count) return [];
  const data = Buffer.from(JSON.stringify({ files: sources.files }), "utf8");
  return [...new Set(buildIds)].map((debugId) => ({ kind: "source-bundle", debugId, name: "sources.json", release: release2, data, gzip: true }));
}
function projectRoot(from, marker) {
  let dir = (0, import_node_path2.resolve)(from);
  for (; ; ) {
    if (marker(dir)) return dir;
    const parent = (0, import_node_path2.dirname)(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}
var FLUTTER_SOURCES = [".dart"];
var APPLE_SOURCES = [".swift", ".m", ".mm", ".h", ".c", ".cc", ".cpp", ".hpp"];
var isFlutterRoot = (dir) => (0, import_node_fs3.existsSync)((0, import_node_path2.join)(dir, "pubspec.yaml"));
var isAppleRoot = (dir) => {
  try {
    return (0, import_node_fs3.existsSync)((0, import_node_path2.join)(dir, "Package.swift")) || (0, import_node_fs3.readdirSync)(dir).some((name) => name.endsWith(".xcodeproj") || name.endsWith(".xcworkspace"));
  } catch {
    return false;
  }
};

// src/native.ts
function withSources(kind, buildIds, options, logger) {
  if (options.sources === false || !buildIds.length) return [];
  const root = typeof options.sources === "string" ? (0, import_node_path3.resolve)(options.sources) : kind === "apple" && process.env.SRCROOT ? process.env.SRCROOT : projectRoot(process.cwd(), kind === "flutter" ? isFlutterRoot : isAppleRoot);
  if (!root || !(0, import_node_fs4.existsSync)(root)) {
    logger.info(`Sources: no ${kind === "flutter" ? "Flutter project (pubspec.yaml)" : "Xcode project"} found from ${process.cwd()} \u2014 pass --sources <project folder>, or --no-sources.`);
    return [];
  }
  const sources = collectSources(root, kind === "flutter" ? FLUTTER_SOURCES : APPLE_SOURCES);
  if (!sources.count) return [];
  logger.info(`With the app's sources: ${sources.count} file(s), ${formatBytes(sources.bytes)} from ${root}${sources.skipped ? ` (${sources.skipped} over the size caps left out)` : ""} \u2014 errors show the code of this build. --no-sources to leave them out.`);
  return sourceBundleArtifacts(sources, buildIds, options.release);
}
var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function send(connection, artifacts, options) {
  const logger = options.logger ?? consoleLogger();
  let done = 0;
  await eachLimit(artifacts, 2, async (artifact) => {
    if (!options.dryRun) {
      if (!connection) throw new Error("No connection to upload to.");
      await uploadArtifact(connection, artifact, { fetch: options.fetch, retries: options.retries });
    }
    done += 1;
    const extra = artifact.arch ? ` ${artifact.arch}` : "";
    logger.info(`  [${done}/${artifacts.length}] ${options.dryRun ? "would upload" : "uploaded"} ${artifact.kind} ${artifact.name}${extra} (${formatBytes(artifact.data.length)})  ${artifact.debugId}`);
  });
  return artifacts;
}
async function uploadProguard(mappingFile, uuid, connection, options = {}) {
  if (!UUID.test(uuid)) throw new Error(`--uuid must be a UUID, got "${uuid}".`);
  const data = (0, import_node_fs4.readFileSync)(mappingFile);
  return send(connection, [{ kind: "proguard", debugId: uuid.toLowerCase(), name: (0, import_node_path3.basename)(mappingFile), release: options.release, data, gzip: true }], options);
}
var DART_ARCH = { x86_64: "x64", x86: "ia32" };
function findDartSymbols(path, logger = consoleLogger()) {
  const files = (0, import_node_fs4.statSync)(path).isDirectory() ? walk((0, import_node_path3.resolve)(path)) : [(0, import_node_path3.resolve)(path)];
  const out = [];
  for (const file of files) {
    const named = /\.symbols$/.test(file);
    const data = (0, import_node_fs4.readFileSync)(file);
    if (!isElf(data)) {
      if (named) logger.warn(`Skipped ${(0, import_node_path3.basename)(file)}: not an ELF file.`);
      continue;
    }
    const elf = readElf(data);
    if (!elf.buildId) {
      logger.warn(`Skipped ${(0, import_node_path3.basename)(file)}: it has no GNU build ID.`);
      continue;
    }
    const match = /\.([a-z]+)-([a-z0-9_]+)\.symbols$/.exec((0, import_node_path3.basename)(file));
    out.push({ path: file, buildId: elf.buildId, os: match?.[1], arch: match?.[2] ?? (elf.arch && (DART_ARCH[elf.arch] ?? elf.arch)) });
  }
  return out;
}
function findObfuscationMap(symbolsPath) {
  const dir = (0, import_node_fs4.statSync)(symbolsPath).isDirectory() ? (0, import_node_path3.resolve)(symbolsPath) : (0, import_node_path3.dirname)((0, import_node_path3.resolve)(symbolsPath));
  for (const where of [dir, (0, import_node_path3.dirname)(dir)]) {
    let names;
    try {
      names = (0, import_node_fs4.readdirSync)(where).sort();
    } catch {
      continue;
    }
    const found = names.find((n) => n === "obfuscation.json") ?? names.find((n) => n.endsWith(".obfuscation.json"));
    if (found && (0, import_node_fs4.statSync)((0, import_node_path3.join)(where, found)).isFile()) return (0, import_node_path3.join)(where, found);
  }
  return void 0;
}
function readObfuscationMap(file) {
  const data = (0, import_node_fs4.readFileSync)(file);
  let parsed;
  try {
    parsed = JSON.parse(data.toString("utf8"));
  } catch (error) {
    throw new Error(`${file} is not valid JSON (${error.message}).`);
  }
  if (!Array.isArray(parsed)) throw new Error(`${file} is not a Dart obfuscation map: expected a JSON array of [obfuscated, original] names.`);
  return data;
}
async function uploadDartSymbols(path, connection, options = {}) {
  const logger = options.logger ?? consoleLogger();
  const files = findDartSymbols(path, logger);
  if (files.length === 0) throw new Error(`No Dart symbol files in ${path} \u2014 build with \`flutter build \u2026 --obfuscate --split-debug-info=<dir>\` and pass that directory.`);
  logger.info(`${options.dryRun ? "Would upload" : "Uploading"} ${files.length} Dart symbol file(s)`);
  const artifacts = files.map((f) => ({
    kind: "dart-symbols",
    debugId: f.buildId,
    name: (0, import_node_path3.basename)(f.path),
    arch: f.arch,
    release: options.release,
    data: (0, import_node_fs4.readFileSync)(f.path),
    gzip: true
  }));
  if (options.obfuscationMap && !(0, import_node_fs4.existsSync)(options.obfuscationMap)) throw new Error(`${options.obfuscationMap} does not exist.`);
  const mapFile = options.obfuscationMap ?? findObfuscationMap(path);
  if (mapFile) {
    const data = readObfuscationMap(mapFile);
    const buildIds = [...new Set(files.map((f) => f.buildId))];
    logger.info(`With obfuscation map ${(0, import_node_path3.basename)(mapFile)} for ${buildIds.length} build ID(s)`);
    for (const debugId of buildIds) {
      artifacts.push({ kind: "dart-obfuscation-map", debugId, name: (0, import_node_path3.basename)(mapFile), release: options.release, data, gzip: true });
    }
  } else {
    logger.info("No obfuscation map found (build with --extra-gen-snapshot-options=--save-obfuscation-map=build/obfuscation.json, or pass --obfuscation-map): obfuscated names in error messages stay as they are.");
  }
  artifacts.push(...withSources("flutter", [...new Set(files.map((f) => f.buildId))], options, logger));
  return send(connection, artifacts, options);
}
function findDsymImages(path) {
  const root = (0, import_node_path3.resolve)(path);
  const candidates = (0, import_node_fs4.statSync)(root).isDirectory() ? walk(root).filter((f) => /[\\/]Contents[\\/]Resources[\\/]DWARF[\\/][^\\/]+$/.test(f)) : [root];
  const out = [];
  for (const file of candidates) {
    const data = (0, import_node_fs4.readFileSync)(file);
    if (!isMachO(data)) continue;
    for (const image of readMachO(data)) out.push({ path: file, ...image });
  }
  return out;
}
async function uploadDsyms(path, connection, options = {}) {
  const logger = options.logger ?? consoleLogger();
  const images = findDsymImages(path);
  if (images.length === 0) throw new Error(`No dSYM DWARF files in ${path} \u2014 pass a .dSYM bundle or the folder that holds them ($DWARF_DSYM_FOLDER_PATH).`);
  logger.info(`${options.dryRun ? "Would upload" : "Uploading"} ${images.length} dSYM image(s)`);
  const cache = /* @__PURE__ */ new Map();
  const artifacts = images.map((image) => {
    let data = cache.get(image.path);
    if (!data) cache.set(image.path, data = (0, import_node_fs4.readFileSync)(image.path));
    return {
      kind: "dsym",
      debugId: image.uuid,
      name: (0, import_node_path3.basename)(image.path),
      arch: image.arch,
      release: options.release,
      // One architecture's slice of a universal file is a complete Mach-O file on its own.
      data: data.subarray(image.offset, image.offset + image.size),
      gzip: true
    };
  });
  const names = swiftNames(images.map((image) => image.path), options.xcodeTool === void 0 ? void 0 : options.xcodeTool);
  if (names && Object.keys(names).length) {
    const data = Buffer.from(JSON.stringify({ names }), "utf8");
    logger.info(`With readable names for ${Object.keys(names).length} Swift symbol(s)`);
    for (const uuid of new Set(images.map((image) => image.uuid))) {
      artifacts.push({ kind: "symbol-names", debugId: uuid, name: "swift-names.json", release: options.release, data, gzip: true });
    }
  } else if (names === null) {
    logger.info("Swift names stay mangled: run the upload on a Mac with Xcode (xcrun swift-demangle) to send readable ones.");
  }
  artifacts.push(...withSources("apple", [...new Set(images.map((image) => image.uuid))], options, logger));
  return send(connection, artifacts, options);
}

// src/sourcemaps.ts
var import_node_fs6 = require("fs");
var import_node_path5 = require("path");

// src/debug-id.ts
var import_node_crypto = require("crypto");
var import_node_fs5 = require("fs");
var import_node_path4 = require("path");
var import_node_url = require("url");
var DEBUG_ID_COMMENT = "//# debugId=";
var DEBUG_ID_PATTERN = /^\/\/# debugId=([0-9a-fA-F-]{36})\s*$/m;
var SOURCE_MAPPING_URL = /^\/\/[#@] sourceMappingURL=(.*?)\s*$/;
function debugIdFromContent(content) {
  const bytes = (0, import_node_crypto.createHash)("sha256").update(content).digest().subarray(0, 16);
  bytes[6] = bytes[6] & 15 | 64;
  bytes[8] = bytes[8] & 63 | 128;
  const hex2 = bytes.toString("hex");
  return `${hex2.slice(0, 8)}-${hex2.slice(8, 12)}-${hex2.slice(12, 16)}-${hex2.slice(16, 20)}-${hex2.slice(20)}`;
}
function registrationSnippet(debugId) {
  return `;!function(){try{var g="undefined"!=typeof globalThis?globalThis:"undefined"!=typeof self?self:"undefined"!=typeof window?window:"undefined"!=typeof global?global:{},s=(new Error).stack;s&&((g.__zharpDebugIds=g.__zharpDebugIds||{})[s]="${debugId}")}catch(e){}}();`;
}
function existingDebugId(code) {
  const lines = code.trimEnd().split("\n");
  for (let i = lines.length - 1; i >= 0 && i >= lines.length - 4; i--) {
    const match = DEBUG_ID_PATTERN.exec(lines[i].trim());
    if (match) return match[1].toLowerCase();
  }
  return void 0;
}
function hasRegistration(code) {
  return code.slice(-2e3).includes(".__zharpDebugIds=");
}
function sourceMappingUrl(code) {
  const lines = code.trimEnd().split("\n");
  for (let i = lines.length - 1; i >= 0 && i >= lines.length - 3; i--) {
    const match = SOURCE_MAPPING_URL.exec(lines[i].trim());
    if (match) return match[1];
  }
  return void 0;
}
function injectCode(code, options = {}) {
  const existing = existingDebugId(code);
  const eol = code.includes("\r\n") ? "\r\n" : "\n";
  if (existing) {
    let out2 = code;
    if (!hasRegistration(code)) {
      const lines2 = code.split(/\r?\n/);
      let at = lines2.length - 1;
      while (at > 0 && !lines2[at].trim().startsWith(DEBUG_ID_COMMENT)) at--;
      lines2.splice(at, 0, registrationSnippet(existing));
      out2 = lines2.join(eol);
    }
    if (options.stripSourceMappingUrl) out2 = withoutSourceMappingUrl(out2);
    return { code: out2, debugId: existing, changed: out2 !== code };
  }
  const debugId = debugIdFromContent(code);
  const lines = code.split(/\r?\n/);
  let tail = [];
  let end = lines.length;
  while (end > 0 && lines[end - 1].trim() === "") end--;
  if (end > 0 && SOURCE_MAPPING_URL.test(lines[end - 1].trim())) {
    tail = options.stripSourceMappingUrl ? [] : [lines[end - 1]];
    end--;
  }
  const body = lines.slice(0, end);
  const out = [...body, registrationSnippet(debugId), `${DEBUG_ID_COMMENT}${debugId}`, ...tail].join(eol) + eol;
  return { code: out, debugId, changed: true };
}
function withoutSourceMappingUrl(code) {
  const lines = code.split(/\r?\n/);
  const eol = code.includes("\r\n") ? "\r\n" : "\n";
  let end = lines.length;
  while (end > 0 && lines[end - 1].trim() === "") end--;
  if (end > 0 && SOURCE_MAPPING_URL.test(lines[end - 1].trim())) return lines.slice(0, end - 1).join(eol) + eol;
  return code;
}
function injectMap(mapText, debugId, mapPath) {
  const map = JSON.parse(mapText);
  if (!map || typeof map !== "object") throw new Error("not a source map");
  const filled = mapPath ? fillSourcesContent(map, mapPath) : 0;
  const hasSourcesContent = Array.isArray(map.sourcesContent) && map.sourcesContent.some((s) => typeof s === "string");
  if (!filled && map.debugId === debugId && map.debug_id === debugId) return { text: mapText, changed: false, hasSourcesContent };
  map.debugId = debugId;
  map.debug_id = debugId;
  return { text: JSON.stringify(map), changed: true, hasSourcesContent };
}
var MAX_SOURCE_BYTES = 1e6;
function sourcePathCandidates(source, mapPath, sourceRoot = "") {
  const mapDir = (0, import_node_path4.dirname)(mapPath);
  let stripped = source;
  let projectRelative = false;
  if (/^turbopack:\/\/\/\[project\]\//.test(source)) {
    stripped = source.replace(/^turbopack:\/\/\/\[project\]\//, "");
    projectRelative = true;
  } else if (/^webpack:\/\//.test(source)) {
    stripped = source.replace(/^webpack:\/\/[^/]*\//, "").replace(/^\.\//, "");
    projectRelative = true;
  } else if (/^file:\/\//.test(source)) {
    try {
      return [(0, import_node_url.fileURLToPath)(source)];
    } catch {
      return [];
    }
  } else if (/^[a-z][\w+.-]*:\/\//i.test(source)) {
    return [];
  }
  if ((0, import_node_path4.isAbsolute)(stripped)) return [stripped];
  const out = [(0, import_node_path4.resolve)(mapDir, sourceRoot, stripped)];
  if (projectRelative) {
    for (let dir = mapDir, i = 0; i < 12; i++) {
      if ((0, import_node_fs5.existsSync)((0, import_node_path4.join)(dir, "package.json"))) {
        out.unshift((0, import_node_path4.join)(dir, stripped));
        break;
      }
      const up = (0, import_node_path4.dirname)(dir);
      if (up === dir) break;
      dir = up;
    }
  }
  return out;
}
function fillSourcesContent(map, mapPath) {
  if (!Array.isArray(map.sources)) return 0;
  const contents = Array.isArray(map.sourcesContent) ? [...map.sourcesContent] : [];
  let filled = 0;
  map.sources.forEach((source, i) => {
    if (typeof contents[i] === "string" || typeof source !== "string") return;
    if (/node_modules|^\[externals\]|\(ignored\)|^webpack\/runtime/.test(source)) return;
    for (const path of sourcePathCandidates(source, mapPath, typeof map.sourceRoot === "string" ? map.sourceRoot : "")) {
      if (/[\\/]node_modules[\\/]/.test(path)) continue;
      try {
        const stat = (0, import_node_fs5.statSync)(path);
        if (!stat.isFile() || stat.size > MAX_SOURCE_BYTES) continue;
        contents[i] = (0, import_node_fs5.readFileSync)(path, "utf8");
        filled++;
        break;
      } catch {
      }
    }
  });
  if (filled) {
    while (contents.length < map.sources.length) contents.push(null);
    map.sourcesContent = contents.map((c) => typeof c === "string" ? c : null);
  }
  return filled;
}

// src/sourcemaps.ts
var JS_FILE = /\.(?:js|mjs|cjs)$/;
function mapFor(file, code) {
  const sibling = `${file}.map`;
  if ((0, import_node_fs6.existsSync)(sibling)) return sibling;
  const url = sourceMappingUrl(code ?? (0, import_node_fs6.readFileSync)(file, "utf8"));
  if (!url || /^[a-z][a-z0-9+.-]*:/i.test(url)) return void 0;
  let path;
  try {
    path = decodeURIComponent(url.split(/[?#]/)[0]);
  } catch {
    return void 0;
  }
  const full = (0, import_node_path5.isAbsolute)(path) ? path : (0, import_node_path5.resolve)((0, import_node_path5.dirname)(file), path);
  return (0, import_node_fs6.existsSync)(full) ? full : void 0;
}
function findSourceFiles(dir, options = {}) {
  const root = (0, import_node_path5.resolve)(dir);
  const keep = pathFilter(options.include, options.exclude);
  const candidates = options.files ? options.files.map((f) => (0, import_node_path5.resolve)(f)) : walk(root);
  const out = [];
  for (const file of candidates) {
    if (!JS_FILE.test(file) || !(0, import_node_fs6.existsSync)(file)) continue;
    const name = relativePath(root, file);
    if (!keep(name)) continue;
    const map = mapFor(file);
    if (map) out.push({ file, map, name, mapName: relativePath(root, map) });
  }
  return out;
}
function injectDirectory(dir, options = {}) {
  const logger = options.logger ?? consoleLogger();
  const files = findSourceFiles(dir, options);
  const out = [];
  const noSourcesContent = [];
  for (const source of files) {
    const code = (0, import_node_fs6.readFileSync)(source.file, "utf8");
    const injected = injectCode(code, { stripSourceMappingUrl: options.stripSourceMappingUrl });
    let map;
    try {
      map = injectMap((0, import_node_fs6.readFileSync)(source.map, "utf8"), injected.debugId, source.map);
    } catch (error) {
      logger.warn(`Skipped ${source.name}: ${source.mapName} is not a readable source map (${error.message}).`);
      continue;
    }
    if (!options.dryRun) {
      if (injected.changed) (0, import_node_fs6.writeFileSync)(source.file, injected.code);
      if (map.changed) (0, import_node_fs6.writeFileSync)(source.map, map.text);
    }
    if (!map.hasSourcesContent) noSourcesContent.push(source.mapName);
    const changed = injected.changed || map.changed;
    out.push({ ...source, debugId: injected.debugId, changed });
    logger.info(`${changed ? options.dryRun ? "would inject" : "injected" : "already has"} ${injected.debugId}  ${source.name}`);
  }
  if (noSourcesContent.length) {
    logger.warn(
      `${noSourcesContent.length} source map(s) have no sourcesContent, so Zharp can show original names and lines but not the code around them: ${noSourcesContent.slice(0, 3).join(", ")}${noSourcesContent.length > 3 ? ", \u2026" : ""}`
    );
  }
  if (out.length === 0) logger.warn(`No JavaScript files with source maps found in ${dir}.`);
  return out;
}
async function uploadSourcemaps(dir, connection, options = {}) {
  const logger = options.logger ?? consoleLogger();
  const files = findSourceFiles(dir, options);
  const result = { files: 0, artifacts: 0, bytes: 0, deleted: [], skipped: [] };
  const work = [];
  for (const source of files) {
    const code = (0, import_node_fs6.readFileSync)(source.file);
    const debugId = existingDebugId(code.toString("utf8"));
    if (!debugId) {
      result.skipped.push(source.name);
      continue;
    }
    work.push({ source, debugId, code, map: (0, import_node_fs6.readFileSync)(source.map) });
  }
  if (result.skipped.length) {
    logger.warn(`${result.skipped.length} file(s) have a source map but no debug ID \u2014 run \`zharp sourcemaps inject\` first: ${result.skipped.slice(0, 3).join(", ")}${result.skipped.length > 3 ? ", \u2026" : ""}`);
  }
  if (work.length === 0) {
    logger.warn(`Nothing to upload in ${dir}.`);
    return result;
  }
  const total = work.length;
  logger.info(`${options.dryRun ? "Would upload" : "Uploading"} ${total} file(s) and their source maps${options.release ? ` for release ${options.release}` : ""}${connection ? ` to ${connection.url}, app ${connection.app}` : ""}`);
  let done = 0;
  await eachLimit(work, options.concurrency ?? 4, async ({ source, debugId, code, map }) => {
    const size = code.length + map.length;
    if (!options.dryRun) {
      if (!connection) throw new Error("No connection to upload to.");
      const common = { debugId, release: options.release };
      const opts = { fetch: options.fetch, retries: options.retries };
      await uploadArtifact(connection, { ...common, kind: "minified-source", name: source.name, data: code }, opts);
      await uploadArtifact(connection, { ...common, kind: "sourcemap", name: source.mapName, data: map }, opts);
    }
    done += 1;
    result.files += 1;
    result.artifacts += 2;
    result.bytes += size;
    logger.info(`  [${done}/${total}] ${options.dryRun ? "would upload" : "uploaded"} ${source.name} + ${source.mapName} (${formatBytes(size)})  ${debugId}`);
  });
  if (options.deleteAfter && !options.dryRun) {
    result.deleted = deleteSourcemaps(work.map((w) => w.source), { stripSourceMappingUrl: options.stripSourceMappingUrl });
    logger.info(`Deleted ${result.deleted.length} source map(s) from the output.`);
  }
  logger.info(`${options.dryRun ? "Dry run: would have uploaded" : "Uploaded"} ${result.artifacts} artifact(s), ${formatBytes(result.bytes)}.`);
  return result;
}
function deleteSourcemaps(files, options = {}) {
  const deleted = [];
  for (const source of files) {
    if (options.stripSourceMappingUrl && (0, import_node_fs6.existsSync)(source.file)) {
      const code = (0, import_node_fs6.readFileSync)(source.file, "utf8");
      const stripped = withoutSourceMappingUrl(code);
      if (stripped !== code) (0, import_node_fs6.writeFileSync)(source.file, stripped);
    }
    if ((0, import_node_fs6.existsSync)(source.map)) {
      (0, import_node_fs6.unlinkSync)(source.map);
      deleted.push(source.mapName);
    }
  }
  return deleted;
}

// src/version.ts
var VERSION = "0.2.1";

// src/init/index.ts
var import_node_child_process3 = require("child_process");
var import_node_fs10 = require("fs");
var import_promises = require("readline/promises");
var import_node_path9 = require("path");

// src/init/connect.ts
var import_node_child_process2 = require("child_process");
var import_node_os = require("os");
var OS_NAMES = { win32: "Windows", darwin: "macOS", linux: "Linux" };
function openBrowser(url) {
  if (process.env.ZHARP_NO_BROWSER || process.env.CI || process.platform === "linux" && !process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) return;
  try {
    const command = process.platform === "win32" ? "cmd" : process.platform === "darwin" ? "open" : "xdg-open";
    const args = process.platform === "win32" ? ["/c", "start", '""', url.replace(/&/g, "^&")] : [url];
    (0, import_node_child_process2.spawn)(command, args, { stdio: "ignore", detached: true }).on("error", () => {
    }).unref();
  } catch {
  }
}
var SetupFailed = class extends Error {
};
async function connect(api, project, hooks) {
  const http = hooks.fetch ?? fetch;
  const sleep2 = hooks.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  const base = `${api.replace(/\/+$/, "")}/api/v1/cli-setup`;
  const opened = await http(`${base}/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json", "user-agent": `zharp-cli/${VERSION}` },
    body: JSON.stringify({ name: project.name, framework: project.label, platform: project.platform, os: OS_NAMES[(0, import_node_os.platform)()] ?? `${(0, import_node_os.platform)()} ${(0, import_node_os.release)()}`, cliVersion: VERSION })
  }).catch((error) => {
    throw new SetupFailed(`Could not reach Zharp at ${api} (${error?.cause?.code ?? error?.message ?? error}).`);
  });
  if (!opened.ok) throw new SetupFailed(`Zharp refused to start a setup (${opened.status}).`);
  const session = (await opened.json()).data;
  hooks.showCode(session.userCode, session.verificationUrl);
  (hooks.openBrowser ?? openBrowser)(session.verificationUrl);
  const until = Date.now() + session.expiresIn * 1e3;
  while (Date.now() < until) {
    await sleep2(Math.max(1, session.interval) * 1e3);
    hooks.waiting?.();
    const res = await http(`${base}/collect`, {
      method: "POST",
      headers: { "content-type": "application/json", "user-agent": `zharp-cli/${VERSION}` },
      body: JSON.stringify({ deviceToken: session.deviceToken })
    }).catch(() => null);
    if (!res) continue;
    const body = await res.json().catch(() => ({}));
    if (res.status === 200 && body?.data?.status === "approved") return body.data;
    if (res.status === 200) continue;
    throw new SetupFailed(body?.message ?? `The setup stopped (${res.status}).`);
  }
  throw new SetupFailed("The code expired before it was approved. Run it again.");
}

// src/init/detect.ts
var import_node_fs7 = require("fs");
var import_node_path6 = require("path");
var read = (path) => {
  try {
    return (0, import_node_fs7.readFileSync)(path, "utf8");
  } catch {
    return null;
  }
};
function majorOf(range) {
  const m = /(\d+)/.exec(range ?? "");
  return m ? ` ${m[1]}` : "";
}
function packageManagerOf(dir) {
  if ((0, import_node_fs7.existsSync)((0, import_node_path6.join)(dir, "pnpm-lock.yaml"))) return "pnpm";
  if ((0, import_node_fs7.existsSync)((0, import_node_path6.join)(dir, "yarn.lock"))) return "yarn";
  if ((0, import_node_fs7.existsSync)((0, import_node_path6.join)(dir, "bun.lockb")) || (0, import_node_fs7.existsSync)((0, import_node_path6.join)(dir, "bun.lock"))) return "bun";
  return "npm";
}
function detect(dir) {
  const pkgText = read((0, import_node_path6.join)(dir, "package.json"));
  const pkg = pkgText ? (() => {
    try {
      return JSON.parse(pkgText);
    } catch {
      return null;
    }
  })() : null;
  const deps = { ...pkg?.dependencies ?? {}, ...pkg?.devDependencies ?? {} };
  const name = typeof pkg?.name === "string" && pkg.name.replace(/^@[^/]+\//, "") || (0, import_node_path6.basename)(dir);
  const base = { dir, name, packageManager: packageManagerOf(dir), typescript: !!deps.typescript || (0, import_node_fs7.existsSync)((0, import_node_path6.join)(dir, "tsconfig.json")), packageJson: pkg ?? void 0 };
  if (deps.next) {
    const appDir = (0, import_node_fs7.existsSync)((0, import_node_path6.join)(dir, "src", "app")) ? "src/app" : (0, import_node_fs7.existsSync)((0, import_node_path6.join)(dir, "app")) ? "app" : void 0;
    return { ...base, framework: "nextjs", label: `Next.js${majorOf(deps.next)}`, platform: "browser", appDir };
  }
  if (deps["@nestjs/core"]) return { ...base, framework: "nestjs", label: `NestJS${majorOf(deps["@nestjs/core"])}`, platform: "node" };
  if (deps.vite && deps.react) return { ...base, framework: "vite-react", label: "React (Vite)", platform: "browser" };
  if (deps.express) return { ...base, framework: "express", label: `Express${majorOf(deps.express)}`, platform: "node" };
  const py = [read((0, import_node_path6.join)(dir, "requirements.txt")), read((0, import_node_path6.join)(dir, "pyproject.toml")), read((0, import_node_path6.join)(dir, "Pipfile"))].filter(Boolean).join("\n").toLowerCase();
  if (py) {
    const pyName = (0, import_node_path6.basename)(dir);
    if (/\bdjango\b/.test(py)) return { ...base, name: pyName, framework: "django", label: "Django", platform: "python" };
    if (/\bfastapi\b/.test(py)) return { ...base, name: pyName, framework: "fastapi", label: "FastAPI", platform: "python" };
    if (/\bflask\b/.test(py)) return { ...base, name: pyName, framework: "flask", label: "Flask", platform: "python" };
  }
  const composer = read((0, import_node_path6.join)(dir, "composer.json"));
  if (composer && /laravel\/framework/.test(composer)) return { ...base, name: (0, import_node_path6.basename)(dir), framework: "laravel", label: "Laravel", platform: "php" };
  const goMod = read((0, import_node_path6.join)(dir, "go.mod"));
  if (goMod !== null) {
    const router = /github\.com\/gin-gonic\/gin/.test(goMod) ? " (Gin)" : /github\.com\/labstack\/echo/.test(goMod) ? " (Echo)" : "";
    const moduleName = /^module\s+(\S+)/m.exec(goMod)?.[1]?.split("/").pop();
    return { ...base, name: moduleName || (0, import_node_path6.basename)(dir), framework: "go", label: `Go${router}`, platform: "go" };
  }
  if (pkg) return { ...base, framework: "node", label: "Node.js", platform: "node" };
  return { ...base, framework: "unknown", label: "an unknown project", platform: "otel" };
}

// src/init/recipes.ts
var import_node_fs9 = require("fs");
var import_node_path8 = require("path");

// src/init/recipes-more.ts
var import_node_fs8 = require("fs");
var import_node_path7 = require("path");
var read2 = (dir, path) => {
  try {
    return (0, import_node_fs8.readFileSync)((0, import_node_path7.join)(dir, path), "utf8").replace(/\r\n/g, "\n");
  } catch {
    return null;
  }
};
var first = (dir, paths) => paths.find((p) => (0, import_node_fs8.existsSync)((0, import_node_path7.join)(dir, p))) ?? null;
function emptyPlan(envFile) {
  return { install: [], devInstall: [], changes: [], manual: [], notes: [], env: { file: envFile ?? "", vars: {} }, commands: [] };
}
var DEFAULT_API = "https://api.zharp.io";
var otlpOf = (api) => {
  const clean = api.replace(/\/+$/, "");
  return clean === DEFAULT_API ? null : `${clean}/api/v1/otlp`;
};
function findFiles(dir, suffix, depth = 3) {
  const skip = /^(node_modules|vendor|\.git|\.venv|venv|env|__pycache__|dist|build|target|\.next|site-packages)$/;
  const out = [];
  const walk2 = (at, level) => {
    let entries;
    try {
      entries = (0, import_node_fs8.readdirSync)(at, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (level < depth && !skip.test(e.name) && !e.name.startsWith(".")) walk2((0, import_node_path7.join)(at, e.name), level + 1);
      } else if (e.name.endsWith(suffix)) {
        out.push((0, import_node_path7.relative)(dir, (0, import_node_path7.join)(at, e.name)).replace(/\\/g, "/"));
      }
    }
  };
  walk2(dir, 0);
  return out.sort((a, b) => a.split("/").length - b.split("/").length || a.localeCompare(b));
}
function nodeEntry(project) {
  const scripts = project.packageJson?.scripts ?? {};
  for (const name of ["start", "dev", "serve"]) {
    const m = /(?:^|\s)(?:node|nodemon|tsx|ts-node)(?:\s+--?[\w-]+(?:[= ][^\s]+)?)*\s+([\w./-]+\.(?:c|m)?[jt]s)\b/.exec(scripts[name] ?? "");
    if (m && (0, import_node_fs8.existsSync)((0, import_node_path7.join)(project.dir, m[1]))) return m[1].replace(/^\.\//, "");
  }
  const main2 = project.packageJson?.main;
  if (typeof main2 === "string" && (0, import_node_fs8.existsSync)((0, import_node_path7.join)(project.dir, main2))) return main2.replace(/^\.\//, "");
  return first(project.dir, ["server.js", "app.js", "index.js", "src/server.js", "src/app.js", "src/index.js", "src/server.ts", "src/app.ts", "src/index.ts", "server.ts", "index.ts"]);
}
function express(project, c, api) {
  const plan = emptyPlan(".env");
  plan.install = ["@zharp/node"];
  const entry = nodeEntry(project);
  const endpoint = otlpOf(api);
  plan.env.vars = { ZHARP_KEY: c.application.ingestKey, ...endpoint ? { ZHARP_ENDPOINT: endpoint } : {} };
  plan.notes.push("Set ZHARP_KEY where the app runs in production.");
  if (!entry) {
    plan.manual.push({ path: "your entry file", why: "start Zharp before anything else loads", snippet: "require('./instrument');  // or: node --import ./instrument.mjs server.js" });
    return plan;
  }
  const main2 = read2(project.dir, entry) ?? "";
  const ts = entry.endsWith(".ts");
  const esm = project.packageJson?.type === "module" || /\.mjs$/.test(entry) || !ts && /^\s*import\s/m.test(main2);
  const dirOf = entry.includes("/") ? entry.slice(0, entry.lastIndexOf("/") + 1) : "";
  const instrumentName = ts ? "instrument.ts" : esm ? entry.endsWith(".mjs") ? "instrument.mjs" : "instrument.js" : entry.endsWith(".cjs") ? "instrument.cjs" : "instrument.js";
  const instrumentPath = `${dirOf}${instrumentName}`;
  const body = [
    "// Before anything else: http, express and the database drivers are instrumented as they load.",
    "try { process.loadEnvFile?.('.env'); } catch { /* no .env: the environment has the key */ }",
    `Zharp.init({ service: '${c.application.serviceName}' });`,
    ""
  ];
  const content = esm || ts ? ["import { Zharp } from '@zharp/node';", "", ...body].join("\n") : ["const { Zharp } = require('@zharp/node');", "", ...body].join("\n");
  if (!(0, import_node_fs8.existsSync)((0, import_node_path7.join)(project.dir, instrumentPath))) plan.changes.push({ path: instrumentPath, kind: "create", content, note: "starts Zharp before the app loads" });
  if (main2.includes("instrument")) return plan;
  if (esm && !ts) {
    const pkgText = read2(project.dir, "package.json");
    let text = pkgText ?? "";
    const preload = `--import ./${instrumentPath}`;
    let changed = false;
    for (const [name, command] of Object.entries(project.packageJson?.scripts ?? {})) {
      if (command.includes(preload)) continue;
      const m = /^(node|nodemon)\s+/.exec(command);
      if (!m || !command.includes(entry.replace(/^\.\//, ""))) continue;
      const next = command.replace(/^(node|nodemon)\s+/, `$1 ${preload} `);
      text = text.replace(`"${name}": ${JSON.stringify(command)}`, `"${name}": ${JSON.stringify(next)}`);
      changed = true;
    }
    if (changed) plan.changes.push({ path: "package.json", kind: "edit", content: text, note: "start scripts preload Zharp (--import)" });
    plan.manual.push({ path: "your start command", why: "ES modules: wherever the app starts outside these scripts, preload Zharp", snippet: `node ${preload} ${entry}` });
    return plan;
  }
  const line = ts ? "import './instrument';" : "require('./instrument');";
  plan.changes.push({ path: entry, kind: "edit", content: `${line}
${main2}`, note: "loads it first" });
  return plan;
}
function pythonInit(c, api) {
  const endpoint = otlpOf(api);
  return [
    "import zharp",
    "",
    "# The app's key can only send data to this app, so it is safe in code.",
    `zharp.init(key="${c.application.ingestKey}", service="${c.application.serviceName}"${endpoint ? `, endpoint="${api.replace(/\/+$/, "")}/api/v1/otlp"` : ""})`
  ].join("\n");
}
function afterPythonImports(text, block) {
  if (/^\s*import zharp\b/m.test(text)) return null;
  const lines = text.split("\n");
  let i = 0;
  while (i < lines.length && /^\s*(#.*)?$/.test(lines[i])) i++;
  if (i < lines.length && /^\s*[rubRUB]*("""|''')/.test(lines[i])) {
    const quote = /("""|''')/.exec(lines[i])[1];
    const rest = lines[i].slice(lines[i].indexOf(quote) + 3);
    if (!rest.includes(quote)) {
      i++;
      while (i < lines.length && !lines[i].includes(quote)) i++;
    }
    i++;
  }
  let last = -1;
  for (let j = i; j < lines.length; j++) {
    if (/^(import |from \S+ import )/.test(lines[j])) {
      last = j;
      if (/\($/.test(lines[j].trim())) while (j < lines.length && !lines[j].includes(")")) last = ++j;
    } else if (!/^\s*(#.*)?$/.test(lines[j])) break;
  }
  const at = last >= 0 ? last + 1 : i;
  return [...lines.slice(0, at), "", block, "", ...lines.slice(at)].join("\n").replace(/\n{4,}/g, "\n\n\n");
}
function pythonInstall(project) {
  const dir = project.dir;
  const changes = [];
  const commands = [];
  const manual = [];
  const requirements = read2(dir, "requirements.txt");
  const pyproject = read2(dir, "pyproject.toml") ?? "";
  if (requirements !== null) {
    if (!/^zharp\b/im.test(requirements)) changes.push({ path: "requirements.txt", kind: "edit", content: `${requirements.replace(/\s*$/, "\n")}zharp
`, note: "adds zharp" });
  }
  const venvPython = first(dir, [".venv/Scripts/python.exe", ".venv/bin/python", "venv/Scripts/python.exe", "venv/bin/python"]);
  if ((0, import_node_fs8.existsSync)((0, import_node_path7.join)(dir, "uv.lock"))) commands.push({ label: "uv add zharp", argv: ["uv", "add", "zharp"] });
  else if (/\[tool\.poetry\]/.test(pyproject)) commands.push({ label: "poetry add zharp", argv: ["poetry", "add", "zharp"] });
  else if (venvPython) commands.push({ label: `install zharp into ${venvPython.split("/")[0]}`, argv: [(0, import_node_path7.join)(dir, venvPython), "-m", "pip", "install", "zharp"] });
  else manual.push({ path: "your Python environment", why: "install the package where the app runs", snippet: "pip install zharp" });
  return { changes, commands, manual };
}
function python(project, c, api) {
  const plan = emptyPlan(null);
  const installed2 = pythonInstall(project);
  plan.changes.push(...installed2.changes);
  plan.commands = installed2.commands;
  plan.manual.push(...installed2.manual);
  const block = pythonInit(c, api);
  let targets = [];
  if (project.framework === "django") {
    targets = [first(project.dir, ["manage.py"]), ...findFiles(project.dir, "wsgi.py"), ...findFiles(project.dir, "asgi.py")].filter((p) => !!p);
  } else {
    const marker = project.framework === "fastapi" ? /\bFastAPI\(/ : /\bFlask\(\s*__name__/;
    const files = findFiles(project.dir, ".py").filter((f) => marker.test(read2(project.dir, f) ?? ""));
    const preferred = files.find((f) => /(^|\/)(main|app|server|wsgi|__init__)\.py$/.test(f)) ?? files[0];
    if (preferred) targets = [preferred];
  }
  for (const path of targets) {
    const text = read2(project.dir, path);
    const edited = text !== null ? afterPythonImports(text, block) : null;
    if (edited) plan.changes.push({ path, kind: "edit", content: edited, note: "starts Zharp" });
  }
  if (!targets.length) {
    const where = project.framework === "django" ? "manage.py, wsgi.py and asgi.py" : project.framework === "fastapi" ? "the file that creates FastAPI()" : "the file that creates Flask(__name__)";
    plan.manual.push({ path: where, why: "start Zharp at the top, after the imports", snippet: block });
  }
  return plan;
}
function laravel(project, c, api) {
  const plan = emptyPlan(".env");
  plan.commands = [{ label: "composer require zharp/zharp", argv: ["composer", "require", "zharp/zharp"] }];
  const endpoint = otlpOf(api);
  plan.env.vars = { ZHARP_KEY: c.application.ingestKey, ZHARP_SERVICE: c.application.serviceName, ...endpoint ? { ZHARP_ENDPOINT: endpoint } : {} };
  plan.notes.push("Laravel finds Zharp by itself (package discovery). Set ZHARP_KEY in production too.");
  void project;
  return plan;
}
var GO_MODULE = "github.com/zharp-io/zharp-go-lib";
function editGoMain(text, c, api, routers) {
  if (text.includes(GO_MODULE)) return null;
  const block = /^import \(\n([\s\S]*?)^\)/m.exec(text);
  const mainFn = /^func main\(\) \{\n/m.exec(text);
  if (!block || !mainFn) return null;
  const imports = block[1];
  const stdlib = [];
  if (!/^\s*"context"$/m.test(imports)) stdlib.push('	"context"');
  const add = [`	zharp "${GO_MODULE}"`];
  let routerLine = "";
  let next = text;
  const gin = routers.gin ? /^(\s*)(\w+) := gin\.(?:Default|New)\(\)\n/m.exec(next) : null;
  const echo = routers.echo ? /^(\s*)(\w+) := echo\.New\(\)\n/m.exec(next) : null;
  if (gin) {
    add.push(`	"${GO_MODULE}/zharpgin"`);
    routerLine = `${gin[1]}${gin[2]}.Use(zharpgin.Middleware())
`;
    next = next.replace(gin[0], gin[0] + routerLine);
  } else if (echo) {
    add.push(`	"${GO_MODULE}/zharpecho"`);
    routerLine = `${echo[1]}${echo[2]}.Use(zharpecho.Middleware())
`;
    next = next.replace(echo[0], echo[0] + routerLine);
  } else {
    next = next.replace(/http\.ListenAndServe\(([^,]+),\s*(nil|[\w.]+)\)/, (_, addr, handler) => `http.ListenAndServe(${addr}, zharp.Handler(${handler === "nil" ? "http.DefaultServeMux" : handler}))`);
  }
  const endpoint = otlpOf(api);
  const start = [
    "	// The app's key can only send data to this app, so it is safe in code.",
    `	shutdown := zharp.Init(zharp.Config{Key: "${c.application.ingestKey}", Service: "${c.application.serviceName}"${endpoint ? `, Endpoint: "${api.replace(/\/+$/, "")}/api/v1/otlp"` : ""}})`,
    "	defer shutdown(context.Background())",
    ""
  ].join("\n");
  next = next.replace(block[0], `import (
${groupedImports(imports, stdlib, add)})`);
  next = next.replace(/^func main\(\) \{\n/m, `func main() {
${start}`);
  return next;
}
function groupedImports(body, stdlib, modules) {
  const groups = body.replace(/\n+$/, "").split(/\n[ \t]*\n/).map((g) => g.split("\n"));
  const isModule = (line) => /"[^"/]*\.[^"/]*\//.test(line) || /"[^"/]*\.[^"/]*"/.test(line);
  const std = groups.find((g) => g.some((l) => /"/.test(l)) && !g.some(isModule));
  const mods = groups.find((g) => g.some(isModule));
  if (stdlib.length) std ? std.push(...stdlib) : groups.unshift(stdlib);
  mods ? mods.push(...modules) : groups.push(modules);
  return `${groups.map((g) => g.join("\n")).join("\n\n")}
`;
}
function go(project, c, api) {
  const plan = emptyPlan(null);
  const goMod = read2(project.dir, "go.mod") ?? "";
  const routers = { gin: /github\.com\/gin-gonic\/gin/.test(goMod), echo: /github\.com\/labstack\/echo/.test(goMod) };
  plan.commands = [{ label: `go get ${GO_MODULE}`, argv: ["go", "get", `${GO_MODULE}@latest`] }];
  if (routers.gin) plan.commands.push({ label: "go get \u2026/zharpgin", argv: ["go", "get", `${GO_MODULE}/zharpgin@latest`] });
  else if (routers.echo) plan.commands.push({ label: "go get \u2026/zharpecho", argv: ["go", "get", `${GO_MODULE}/zharpecho@latest`] });
  const mainPath = first(project.dir, ["main.go", "cmd/server/main.go", "cmd/api/main.go", "cmd/main.go"]) ?? findFiles(project.dir, "main.go").find((f) => /func main\(\)/.test(read2(project.dir, f) ?? "")) ?? null;
  const text = mainPath ? read2(project.dir, mainPath) : null;
  const edited = text ? editGoMain(text, c, api, routers) : null;
  if (mainPath && edited) {
    plan.changes.push({ path: mainPath, kind: "edit", content: edited, note: `starts Zharp${routers.gin ? "; traces Gin" : routers.echo ? "; traces Echo" : ""}` });
    plan.commands.push({ label: "go mod tidy", argv: ["go", "mod", "tidy"] });
    plan.commands.push({ label: `gofmt -w ${mainPath}`, argv: ["gofmt", "-w", mainPath] });
  } else if (!text?.includes(GO_MODULE)) {
    plan.manual.push({ path: mainPath ?? "main.go", why: "start Zharp first in main()", snippet: `shutdown := zharp.Init(zharp.Config{Key: "${c.application.ingestKey}"})
defer shutdown(context.Background())` });
  }
  return plan;
}
function morePlanFor(project, c, api) {
  switch (project.framework) {
    case "express":
      return express(project, c, api);
    case "django":
    case "fastapi":
    case "flask":
      return python(project, c, api);
    case "laravel":
      return laravel(project, c, api);
    case "go":
      return go(project, c, api);
    default:
      return null;
  }
}

// src/init/recipes.ts
var DEFAULT_API2 = "https://api.zharp.io";
var read3 = (dir, path) => {
  try {
    return (0, import_node_fs9.readFileSync)((0, import_node_path8.join)(dir, path), "utf8").replace(/\r\n/g, "\n");
  } catch {
    return null;
  }
};
var first2 = (dir, paths) => paths.find((p) => (0, import_node_fs9.existsSync)((0, import_node_path8.join)(dir, p))) ?? null;
var mentionsZharp = (text) => !!text && /@zharp\//.test(text);
function styled(text, line) {
  const imports = [...text.matchAll(/^import .*$/gm)].map((m) => m[0].trimEnd());
  const bare = imports.length > 0 && imports.every((l) => !l.endsWith(";"));
  const double = imports.filter((l) => /from "/.test(l)).length > imports.filter((l) => /from '/.test(l)).length;
  const quoted = double ? line.replace(/'([^'"]*)'/g, '"$1"') : line;
  return bare ? quoted.replace(/;$/, "") : quoted;
}
function endpointOf(api) {
  const clean = api.replace(/\/+$/, "");
  return clean === DEFAULT_API2 ? null : `${clean}/api/v1/otlp`;
}
function wrapNextConfig(text, appId, esm) {
  if (/withZharp/.test(text)) return null;
  const exportDefault = /export\s+default\s+([\s\S]+?);?\s*$/.exec(text);
  if (esm && exportDefault) {
    const value = exportDefault[1].trim().replace(/;$/, "");
    const head = text.slice(0, exportDefault.index);
    return `import { withZharp } from '@zharp/nextjs';
${head}export default withZharp(${value}, { app: ${appId} });
`;
  }
  const moduleExports = /module\.exports\s*=\s*([\s\S]+?);?\s*$/.exec(text);
  if (!esm && moduleExports) {
    const value = moduleExports[1].trim().replace(/;$/, "");
    const head = text.slice(0, moduleExports.index);
    return `const { withZharp } = require('@zharp/nextjs');
${head}module.exports = withZharp(${value}, { app: ${appId} });
`;
  }
  return null;
}
function addToLayout(text, importPath) {
  if (/ZharpClient/.test(text)) return null;
  const body = /<body\b[^>]*>/.exec(text);
  if (!body) return null;
  const at = body.index + body[0].length;
  const bodyIndent = /[ \t]*$/.exec(text.slice(0, body.index))[0];
  const inner = `${bodyIndent}  `;
  const rest = text.slice(at);
  const after = /^\s*\n/.test(rest) ? rest : `
${inner}${rest.replace(/^[ \t]+/, "")}`;
  const withComponent = `${text.slice(0, at)}
${inner}<ZharpClient />${after}`;
  const imports = [...withComponent.matchAll(/^import .*$/gm)];
  const line = styled(text, `import { ZharpClient } from '${importPath}';`);
  if (!imports.length) return `${line}
${withComponent}`;
  const last = imports[imports.length - 1];
  const end = last.index + last[0].length;
  return `${withComponent.slice(0, end)}
${line}${withComponent.slice(end)}`;
}
function nextjs(project, c, api) {
  const dir = project.dir;
  const ts = project.typescript;
  const plan = { install: ["@zharp/browser", "@zharp/node"], devInstall: ["@zharp/nextjs"], changes: [], manual: [], notes: [], env: { file: ".env.local", vars: {} } };
  const endpoint = endpointOf(api);
  const instrumentationPath = `${project.appDir?.startsWith("src/") ? "src/" : ""}instrumentation.${ts ? "ts" : "js"}`;
  const instrumentation = [
    "export async function register() {",
    "  if (process.env.NEXT_RUNTIME === 'nodejs') {",
    "    const { Zharp } = await import('@zharp/node');",
    `    Zharp.init({ service: '${c.application.serviceName}' });`,
    "  }",
    "}",
    "",
    "// Errors Next.js answers with an error page: reported with their route.",
    `export async function onRequestError(...args${ts ? ": Parameters<typeof import('@zharp/node').Zharp.onRequestError>" : ""}) {`,
    "  if (process.env.NEXT_RUNTIME === 'nodejs') {",
    "    const { Zharp } = await import('@zharp/node');",
    "    Zharp.onRequestError(...args);",
    "  }",
    "}",
    ""
  ].join("\n");
  const existingInstrumentation = first2(dir, ["instrumentation.ts", "instrumentation.js", "src/instrumentation.ts", "src/instrumentation.js"]);
  if (!existingInstrumentation) plan.changes.push({ path: instrumentationPath, kind: "create", content: instrumentation, note: "starts Zharp on the server" });
  else if (!mentionsZharp(read3(dir, existingInstrumentation))) plan.manual.push({ path: existingInstrumentation, why: "it already exists \u2014 add Zharp to it", snippet: instrumentation });
  const configPath = first2(dir, ["next.config.ts", "next.config.mjs", "next.config.js", "next.config.cjs"]);
  if (!configPath) {
    plan.changes.push({ path: ts ? "next.config.ts" : "next.config.mjs", kind: "create", content: `import { withZharp } from '@zharp/nextjs';

export default withZharp({}, { app: ${c.application.id} });
`, note: "source maps uploaded on build" });
  } else {
    const text = read3(dir, configPath) ?? "";
    const esm = /\.(ts|mjs)$/.test(configPath) || /^\s*(import|export)\s/m.test(text);
    const wrapped = mentionsZharp(text) ? null : wrapNextConfig(text, c.application.id, esm);
    if (wrapped) plan.changes.push({ path: configPath, kind: "edit", content: wrapped, note: "wrapped with withZharp" });
    else if (!mentionsZharp(text)) plan.manual.push({ path: configPath, why: "its export isn't a plain value \u2014 wrap it yourself", snippet: `import { withZharp } from '@zharp/nextjs';

export default withZharp(nextConfig, { app: ${c.application.id} });` });
  }
  if (project.appDir) {
    const ext = ts ? "tsx" : "jsx";
    const clientPath = `${project.appDir}/zharp-client.${ext}`;
    const client = [
      "'use client';",
      "import { Zharp } from '@zharp/browser';",
      "",
      "if (typeof window !== 'undefined' && !Zharp.isActive) {",
      `  Zharp.init({ key: process.env.NEXT_PUBLIC_ZHARP_KEY${ts ? "!" : ""}${endpoint ? ", endpoint: process.env.NEXT_PUBLIC_ZHARP_ENDPOINT" : ""}, service: '${c.application.serviceName}' });`,
      "}",
      "",
      "/** Starts Zharp in the browser; rendered once, in the root layout. */",
      "export function ZharpClient() {",
      "  return null;",
      "}",
      ""
    ].join("\n");
    if (!(0, import_node_fs9.existsSync)((0, import_node_path8.join)(dir, clientPath))) plan.changes.push({ path: clientPath, kind: "create", content: client, note: `starts Zharp in the browser` });
    const layoutPath = first2(dir, [`${project.appDir}/layout.tsx`, `${project.appDir}/layout.jsx`, `${project.appDir}/layout.js`]);
    const layout = layoutPath ? read3(dir, layoutPath) : null;
    const edited = layout ? addToLayout(layout, "./zharp-client") : null;
    if (layoutPath && edited) plan.changes.push({ path: layoutPath, kind: "edit", content: edited, note: "renders <ZharpClient />" });
    else if (layoutPath && !/ZharpClient/.test(layout ?? "")) plan.manual.push({ path: layoutPath, why: "add the component inside <body>", snippet: "import { ZharpClient } from './zharp-client';\n\u2026\n<body>\n  <ZharpClient />" });
  } else {
    plan.manual.push({ path: "pages/_app", why: "pages router: start Zharp in your _app", snippet: "import { Zharp } from '@zharp/browser';\n\nif (typeof window !== 'undefined') Zharp.init({ key: process.env.NEXT_PUBLIC_ZHARP_KEY });" });
  }
  plan.env.vars = {
    NEXT_PUBLIC_ZHARP_KEY: c.application.ingestKey,
    ZHARP_KEY: c.application.ingestKey,
    ZHARP_AUTH_TOKEN: c.uploadKey,
    ...endpoint ? { NEXT_PUBLIC_ZHARP_ENDPOINT: endpoint, ZHARP_ENDPOINT: endpoint, ZHARP_URL: api.replace(/\/+$/, "") } : {}
  };
  plan.notes.push("Add ZHARP_AUTH_TOKEN (and the keys) to your CI and hosting, so production builds upload their source maps.");
  return plan;
}
function addVitePlugin(text, appId) {
  if (/@zharp\/vite-plugin/.test(text)) return null;
  const plugins = /plugins\s*:\s*\[/.exec(text);
  if (!plugins) return null;
  let depth = 0;
  let close = -1;
  for (let i = plugins.index + plugins[0].length; i < text.length; i++) {
    const ch = text[i];
    if (ch === "[" || ch === "(" || ch === "{") depth++;
    else if (ch === "]" || ch === ")" || ch === "}") {
      if (depth === 0 && ch === "]") {
        close = i;
        break;
      }
      depth--;
    }
  }
  if (close < 0) return null;
  const inside = text.slice(plugins.index + plugins[0].length, close).trimEnd();
  const sep2 = inside.length === 0 ? "" : inside.endsWith(",") ? " " : ", ";
  const withPlugin = `${text.slice(0, plugins.index + plugins[0].length)}${inside}${sep2}zharp({ app: ${appId} })${text.slice(close)}`;
  const imports = [...withPlugin.matchAll(/^import .*$/gm)];
  const line = styled(text, "import { zharp } from '@zharp/vite-plugin';");
  if (!imports.length) return `${line}
${withPlugin}`;
  const last = imports[imports.length - 1];
  const end = last.index + last[0].length;
  return `${withPlugin.slice(0, end)}
${line}${withPlugin.slice(end)}`;
}
function addToViteMain(text, serviceName, withEndpoint) {
  if (/@zharp\/browser/.test(text)) return null;
  const call = /createRoot\(([^()]*(?:\([^()]*\)[^()]*)*)\)/.exec(text);
  let next = text;
  if (call && !call[1].includes(",")) {
    next = `${text.slice(0, call.index)}createRoot(${call[1]}, {
  onUncaughtError: Zharp.reactErrorHandler(),
  onCaughtError: Zharp.reactErrorHandler(),
})${text.slice(call.index + call[0].length)}`;
  }
  const imports = [...next.matchAll(/^import .*$/gm)];
  const start = styled(text, `Zharp.init({ key: import.meta.env.VITE_ZHARP_KEY${withEndpoint ? ", endpoint: import.meta.env.VITE_ZHARP_ENDPOINT" : ""}, service: '${serviceName}' });`);
  const init = `
${start}
`;
  const line = styled(text, "import { Zharp } from '@zharp/browser';");
  if (!imports.length) return `${line}
${init}
${next}`;
  const last = imports[imports.length - 1];
  const end = last.index + last[0].length;
  return `${next.slice(0, end)}
${line}
${init}${next.slice(end).replace(/^\n+/, "\n")}`;
}
function viteReact(project, c, api) {
  const dir = project.dir;
  const endpoint = endpointOf(api);
  const plan = { install: ["@zharp/browser"], devInstall: ["@zharp/vite-plugin"], changes: [], manual: [], notes: [], env: { file: ".env.local", vars: {} } };
  const configPath = first2(dir, ["vite.config.ts", "vite.config.mts", "vite.config.js", "vite.config.mjs"]);
  const config = configPath ? read3(dir, configPath) : null;
  const editedConfig = config ? addVitePlugin(config, c.application.id) : null;
  if (configPath && editedConfig) plan.changes.push({ path: configPath, kind: "edit", content: editedConfig, note: "source maps uploaded on build" });
  else if (!mentionsZharp(config)) plan.manual.push({ path: configPath ?? "vite.config.ts", why: "add the plugin to plugins", snippet: `import { zharp } from '@zharp/vite-plugin';
\u2026
plugins: [react(), zharp({ app: ${c.application.id} })]` });
  const mainPath = first2(dir, ["src/main.tsx", "src/main.jsx", "src/main.ts", "src/main.js", "src/index.tsx", "src/index.jsx"]);
  const main2 = mainPath ? read3(dir, mainPath) : null;
  const editedMain = main2 ? addToViteMain(main2, c.application.serviceName, !!endpoint) : null;
  if (mainPath && editedMain) plan.changes.push({ path: mainPath, kind: "edit", content: editedMain, note: "starts Zharp; React errors with their component stack" });
  else if (!mentionsZharp(main2)) plan.manual.push({ path: mainPath ?? "src/main.tsx", why: "start Zharp before React renders", snippet: "import { Zharp } from '@zharp/browser';\n\nZharp.init({ key: import.meta.env.VITE_ZHARP_KEY });\n\ncreateRoot(el, { onUncaughtError: Zharp.reactErrorHandler(), onCaughtError: Zharp.reactErrorHandler() })" });
  plan.env.vars = {
    VITE_ZHARP_KEY: c.application.ingestKey,
    ZHARP_AUTH_TOKEN: c.uploadKey,
    ...endpoint ? { VITE_ZHARP_ENDPOINT: endpoint, ZHARP_URL: api.replace(/\/+$/, "") } : {}
  };
  plan.notes.push("Add ZHARP_AUTH_TOKEN and VITE_ZHARP_KEY to your CI, so production builds upload their source maps.");
  return plan;
}
function nestjs(project, c, api) {
  const dir = project.dir;
  const endpoint = endpointOf(api);
  const plan = { install: ["@zharp/node"], devInstall: [], changes: [], manual: [], notes: [], env: { file: ".env", vars: {} } };
  const ext = project.typescript ? "ts" : "js";
  const instrumentPath = `src/instrument.${ext}`;
  const instrument = [
    "import { Zharp } from '@zharp/node';",
    "",
    "// Before anything else: http, the database drivers and NestJS are instrumented as they load.",
    "try { process.loadEnvFile?.('.env'); } catch { /* no .env: the environment has the keys */ }",
    `Zharp.init({ service: '${c.application.serviceName}' });`,
    ""
  ].join("\n");
  if (!(0, import_node_fs9.existsSync)((0, import_node_path8.join)(dir, instrumentPath))) plan.changes.push({ path: instrumentPath, kind: "create", content: instrument, note: "starts Zharp before the app loads" });
  const mainPath = first2(dir, [`src/main.${ext}`]);
  const main2 = mainPath ? read3(dir, mainPath) : null;
  const esm = project.packageJson?.type === "module" || /from '\.{1,2}\/[^']+\.js'/.test(main2 ?? "");
  if (esm) {
    const pkgText = read3(dir, "package.json");
    const scripts = { ...project.packageJson?.scripts ?? {} };
    const preload = "--import ./dist/instrument.js";
    let changed = false;
    for (const [name, command] of Object.entries(scripts)) {
      if (command.includes(preload)) continue;
      if (/^nest start\b/.test(command) && !/--exec\b/.test(command)) {
        scripts[name] = `${command} --exec "node ${preload}"`;
        changed = true;
      } else if (/^node (?:--[^\s]+ )*dist\/main(?:\.js)?\s*$/.test(command)) {
        scripts[name] = command.replace(/^node /, `node ${preload} `);
        changed = true;
      }
    }
    if (changed && pkgText) {
      let text = pkgText;
      for (const [name, command] of Object.entries(scripts)) {
        const before = (project.packageJson?.scripts ?? {})[name];
        if (before === command) continue;
        const line = new RegExp(`("${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"\\s*:\\s*)${JSON.stringify(before).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`);
        text = text.replace(line, (_, key) => `${key}${JSON.stringify(command)}`);
      }
      plan.changes.push({ path: "package.json", kind: "edit", content: text, note: "start scripts preload Zharp (--import)" });
    }
    plan.manual.push({ path: "your start command", why: "ES modules: wherever the app is started outside these scripts (a Dockerfile, a process manager), preload Zharp", snippet: `node ${preload} dist/main.js` });
  } else if (mainPath && main2 && !main2.includes("./instrument")) {
    plan.changes.push({ path: mainPath, kind: "edit", content: `${styled(main2, "import './instrument';")}
${main2}`, note: "loads it first" });
  } else if (!mainPath) {
    plan.manual.push({ path: "src/main.ts", why: "import it first in your entry file", snippet: "import './instrument';" });
  }
  plan.env.vars = { ZHARP_KEY: c.application.ingestKey, ...endpoint ? { ZHARP_ENDPOINT: endpoint } : {} };
  plan.notes.push("Set ZHARP_KEY where the app runs in production.");
  return plan;
}
function planFor(project, c, api) {
  const plan = basePlanFor(project, c, api);
  for (const ch of plan?.changes ?? []) {
    if (ch.kind !== "edit") continue;
    try {
      if ((0, import_node_fs9.readFileSync)((0, import_node_path8.join)(project.dir, ch.path), "utf8").includes("\r\n")) ch.content = ch.content.replace(/\r?\n/g, "\r\n");
    } catch {
    }
  }
  return plan;
}
function basePlanFor(project, c, api) {
  switch (project.framework) {
    case "nextjs":
      return nextjs(project, c, api);
    case "vite-react":
      return viteReact(project, c, api);
    case "nestjs":
      return nestjs(project, c, api);
    default:
      return morePlanFor(project, c, api);
  }
}
var GUIDES = {
  express: "https://zharp.io/docs/sdks/node",
  node: "https://zharp.io/docs/sdks/node",
  django: "https://zharp.io/docs/sdks/python",
  fastapi: "https://zharp.io/docs/sdks/python",
  flask: "https://zharp.io/docs/sdks/python",
  laravel: "https://zharp.io/docs/sdks/php",
  go: "https://zharp.io/docs/sdks/go"
};

// src/init/index.ts
var green = (s) => `\x1B[32m${s}\x1B[39m`;
var dim = (s) => `\x1B[2m${s}\x1B[22m`;
var bold = (s) => `\x1B[1m${s}\x1B[22m`;
var yellow = (s) => `\x1B[33m${s}\x1B[39m`;
var bar = dim("\u2502");
function say(line = "") {
  process.stdout.write(`${line}
`);
}
function mergeEnv(existing, vars) {
  const lines = existing ? existing.replace(/\s+$/, "").split(/\r?\n/) : [];
  const seen = /* @__PURE__ */ new Set();
  const out = lines.map((line) => {
    const name = /^\s*(?:export\s+)?([A-Z0-9_]+)\s*=/.exec(line)?.[1];
    if (name && name in vars) {
      seen.add(name);
      return `${name}=${vars[name]}`;
    }
    return line;
  });
  const added = Object.entries(vars).filter(([k]) => !seen.has(k));
  if (added.length) {
    if (out.length) out.push("");
    out.push("# Zharp (npm init zharp@latest)");
    for (const [k, v] of added) out.push(`${k}=${v}`);
  }
  return `${out.join("\n")}
`;
}
function ignoredByGit(gitignore, file) {
  return gitignore.split(/\r?\n/).map((l) => l.trim()).some((l) => l === file || l === `/${file}` || l === ".env*" || l === ".env*.local" && file.endsWith(".local") || l === "*.local" && file.endsWith(".local") || l === ".env.*" && file !== ".env");
}
function installCommand(project, packages, dev, tarballs) {
  const specs = tarballs ? packages.map((p) => (0, import_node_path9.join)(tarballs, `${p.replace("@", "").replace("/", "-")}.tgz`)) : packages;
  switch (project.packageManager) {
    case "pnpm":
      return ["pnpm", ["add", ...dev ? ["-D"] : [], ...specs]];
    case "yarn":
      return ["yarn", ["add", ...dev ? ["-D"] : [], ...specs]];
    case "bun":
      return ["bun", ["add", ...dev ? ["-d"] : [], ...specs]];
    default:
      return ["npm", ["install", ...dev ? ["--save-dev"] : [], ...specs]];
  }
}
function installed(command) {
  const found = process.platform === "win32" ? (0, import_node_child_process3.spawnSync)("where", [command], { stdio: "ignore" }) : (0, import_node_child_process3.spawnSync)("sh", ["-c", 'command -v "$0"', command], { stdio: "ignore" });
  return found.status === 0;
}
async function ask(question) {
  const rl = (0, import_promises.createInterface)({ input: process.stdin, output: process.stdout });
  try {
    return (await rl.question(question)).trim().toLowerCase();
  } finally {
    rl.close();
  }
}
async function sendTestError(api, c) {
  const now = `${Date.now()}000000`;
  const attr = (key, value) => ({ key, value: { stringValue: value } });
  const body = {
    resourceLogs: [{
      resource: { attributes: [attr("service.name", c.application.serviceName), attr("telemetry.sdk.name", "zharp-cli")] },
      scopeLogs: [{
        logRecords: [{
          timeUnixNano: now,
          severityNumber: 17,
          severityText: "ERROR",
          body: { stringValue: "ZharpSetupTest: Zharp is connected \u2014 this is the test error npm init zharp@latest sent" },
          attributes: [
            attr("exception.type", "ZharpSetupTest"),
            attr("exception.message", "Zharp is connected \u2014 this is the test error npm init zharp@latest sent"),
            attr("exception.stacktrace", "ZharpSetupTest: Zharp is connected \u2014 this is the test error npm init zharp@latest sent\n    at zharp init"),
            attr("zharp.handled", "true")
          ]
        }]
      }]
    }]
  };
  try {
    const res = await fetch(`${api.replace(/\/+$/, "")}/api/v1/otlp/v1/logs`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${c.application.ingestKey}` },
      body: JSON.stringify(body)
    });
    return res.ok;
  } catch {
    return false;
  }
}
function showPlan(plan, c) {
  say(`${green("\u25C6")} ${bold("These changes will be made:")}`);
  const deps = [...plan.install, ...plan.devInstall];
  if (deps.length) say(`${bar}  ${green("+")} install ${deps.join(" ")}`);
  for (const cmd of plan.commands ?? []) say(`${bar}  ${green("+")} ${cmd.label}`);
  for (const ch of plan.changes) say(`${bar}  ${ch.kind === "create" ? green("+") : yellow("~")} ${bold(ch.path)}   ${dim(ch.kind === "create" ? `(new) ${ch.note}` : ch.note)}`);
  if (plan.env.file) say(`${bar}  ${green("+")} ${bold(plan.env.file)}   ${dim(Object.keys(plan.env.vars).join(", "))}`);
  for (const m of plan.manual) say(`${bar}  ${yellow("!")} ${m.path}: ${dim(`left as it is \u2014 ${m.why}`)}`);
  void c;
}
async function runInit(options) {
  const dir = (0, import_node_path9.resolve)(options.dir ?? process.cwd());
  const api = (options.url ?? process.env.ZHARP_URL ?? DEFAULT_API2).replace(/\/+$/, "");
  const project = detect(dir);
  say();
  say(`${green("\u25C6")} ${bold("Zharp setup")}`);
  say(`${bar} Found ${bold(project.label)} in ${dim(dir)}`);
  say(bar);
  let connected;
  try {
    connected = await connect(api, project, {
      showCode(code, url) {
        say(`${bar} Open ${url} and check this code:`);
        say(bar);
        say(`${bar}     ${bold(code)}`);
        say(bar);
        say(`${bar} ${dim("Waiting for you to approve it in the browser\u2026")}`);
      }
    });
  } catch (error) {
    say(`${yellow("\u25A0")} ${error instanceof SetupFailed ? error.message : String(error)}`);
    return 1;
  }
  say(`${green("\u25C7")} Connected to ${bold(`${connected.workspace.name} / ${connected.application.name}`)}`);
  say(bar);
  const plan = planFor(project, connected, api);
  if (!plan) {
    say(`${green("\u25C6")} ${bold(`${project.label}: add the SDK with these keys`)}`);
    say(`${bar}  ZHARP_KEY=${connected.application.ingestKey}`);
    say(`${bar}  ${dim("Upload key (source maps): ZHARP_AUTH_TOKEN=")}${connected.uploadKey}`);
    const guide = GUIDES[project.framework];
    say(`${bar}  ${dim(`How: ${guide ?? "https://zharp.io/docs"}`)}`);
    return 0;
  }
  showPlan(plan, connected);
  say(bar);
  if (options.dryRun) {
    say(`${green("\u25C7")} Dry run: nothing was changed.`);
    return 0;
  }
  if (!options.yes) {
    for (; ; ) {
      const answer = await ask(`${green("\u25C6")} Apply? ${dim("[Y]es / [n]o / show the [d]iff")} `);
      if (answer === "d" || answer === "diff") {
        for (const ch of plan.changes) {
          say(`
${bold(`\u2500\u2500 ${ch.path} ${ch.kind === "create" ? "(new)" : "(edited)"}`)}`);
          say(ch.content);
        }
        continue;
      }
      if (answer === "n" || answer === "no") {
        say(`${yellow("\u25A0")} Nothing was changed. The app is set up in Zharp: ${connected.appUrl}`);
        return 0;
      }
      break;
    }
  }
  for (const ch of plan.changes) {
    const path = (0, import_node_path9.join)(dir, ch.path);
    (0, import_node_fs10.mkdirSync)((0, import_node_path9.dirname)(path), { recursive: true });
    (0, import_node_fs10.writeFileSync)(path, ch.content);
  }
  if (plan.env.file) {
    const envPath = (0, import_node_path9.join)(dir, plan.env.file);
    (0, import_node_fs10.writeFileSync)(envPath, mergeEnv((0, import_node_fs10.existsSync)(envPath) ? (0, import_node_fs10.readFileSync)(envPath, "utf8") : "", plan.env.vars));
    const gitignorePath = (0, import_node_path9.join)(dir, ".gitignore");
    if ((0, import_node_fs10.existsSync)((0, import_node_path9.join)(dir, ".git")) || (0, import_node_fs10.existsSync)(gitignorePath)) {
      const gitignore = (0, import_node_fs10.existsSync)(gitignorePath) ? (0, import_node_fs10.readFileSync)(gitignorePath, "utf8") : "";
      if (!ignoredByGit(gitignore, plan.env.file)) (0, import_node_fs10.writeFileSync)(gitignorePath, `${gitignore.replace(/\s*$/, "\n")}${plan.env.file}
`);
    }
  }
  say(`${green("\u25C7")} Files written`);
  const run = (command, args) => {
    if (!(0, import_node_path9.isAbsolute)(command) && !installed(command)) return "missing";
    say(`${bar} ${dim(`${command} ${args.join(" ")}`)}`);
    const result = process.platform === "win32" ? (0, import_node_child_process3.spawnSync)([command, ...args].map((a) => /[\s"&|<>^]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a).join(" "), { cwd: dir, stdio: "inherit", shell: true }) : (0, import_node_child_process3.spawnSync)(command, args, { cwd: dir, stdio: "inherit" });
    if (result.error?.code === "ENOENT" || process.platform === "win32" && result.status === 9009 || process.platform !== "win32" && result.status === 127) return "missing";
    return result.status === 0 ? "ok" : "failed";
  };
  for (const [packages, dev] of [[plan.install, false], [plan.devInstall, true]]) {
    if (!packages.length) continue;
    const [command, args] = installCommand(project, [...packages], dev, options.tarballs);
    if (run(command, args) !== "ok") {
      say(`${yellow("\u25A0")} The install failed. Run it yourself: ${command} ${args.join(" ")}`);
      return 1;
    }
  }
  const leftToDo = [];
  for (const cmd of plan.commands ?? []) {
    const [command, ...args] = cmd.argv;
    const result = run(command, args);
    if (result === "missing") leftToDo.push(`${cmd.argv.join(" ")}   ${dim(`(${command} isn't installed here)`)}`);
    else if (result === "failed") leftToDo.push(cmd.argv.join(" "));
  }
  say(`${green("\u25C7")} ${leftToDo.length ? "Set up \u2014 finish with:" : "Packages installed"}`);
  for (const line of leftToDo) say(`${bar}   ${line}`);
  for (const m of plan.manual) {
    say(bar);
    say(`${yellow("!")} ${bold(m.path)} \u2014 ${m.why}:`);
    for (const line of m.snippet.split("\n")) say(`${bar}   ${line}`);
  }
  for (const note of plan.notes) say(`${bar} ${yellow("!")} ${note}`);
  const sent = await sendTestError(api, connected);
  say(bar);
  say(sent ? `${green("\u25C7")} Done. Sent a test error \u2014 see it at ${connected.appUrl}` : `${green("\u25C7")} Done. Open ${connected.appUrl} \u2014 errors show up as your app sends them.`);
  return 0;
}

// src/cli.ts
var HELP = `zharp ${VERSION} \u2014 readable stack traces for Zharp

Usage:
  zharp init                                            Connect this project to Zharp and set it up
                                                        (also: npm init zharp@latest)
        [--yes] [--dry-run]                             (signs in through the browser)
  zharp sourcemaps inject <dir>                         Add debug IDs to JS files and their maps
  zharp sourcemaps upload <dir> --app <id>              Upload JS files and their maps
        [--release <r>] [--delete-after]
  zharp proguard upload <mapping.txt> --app <id> --uuid <uuid>
  zharp dart-symbols upload <dir> --app <id>            Flutter --split-debug-info output
        [--obfuscation-map <file>]                      (and its obfuscation map)
  zharp dsym upload <path> --app <id>                   A .dSYM, or a folder of them

Options:
  --app <id>          Application ID (or ZHARP_APP)
  --release <r>       Release name to file the upload under (or ZHARP_RELEASE)
  --include <glob>    Only these files (repeatable; sourcemaps)
  --exclude <glob>    Not these files (repeatable; sourcemaps)
  --sources <dir>     The project whose sources go with the symbols (dart-symbols, dsym; default: found)
  --no-sources        Don't upload the app's sources (errors then show code only from a linked repo)
  --delete-after      Delete .map files after uploading them
  --dry-run           Show what would happen; change and send nothing
  --url <url>         Zharp API (default ZHARP_URL or https://api.zharp.io)
  -h, --help, -v, --version

Environment:
  ZHARP_AUTH_TOKEN    A workspace API key with the "artifacts:write" scope (required to upload)
  ZHARP_URL           The Zharp API, default https://api.zharp.io
`;
var UsageError = class extends Error {
};
function fail(message) {
  throw new UsageError(message);
}
async function main(argv) {
  const { values, positionals } = (0, import_node_util.parseArgs)({
    args: argv,
    allowPositionals: true,
    options: {
      app: { type: "string" },
      release: { type: "string" },
      uuid: { type: "string" },
      "obfuscation-map": { type: "string" },
      sources: { type: "string" },
      "no-sources": { type: "boolean" },
      include: { type: "string", multiple: true },
      exclude: { type: "string", multiple: true },
      "delete-after": { type: "boolean" },
      "dry-run": { type: "boolean" },
      yes: { type: "boolean", short: "y" },
      tarballs: { type: "string" },
      url: { type: "string" },
      help: { type: "boolean", short: "h" },
      version: { type: "boolean", short: "v" }
    }
  });
  if (values.version) {
    console.log(VERSION);
    return;
  }
  const [group, command, target] = positionals;
  if (values.help || !group) {
    console.log(HELP);
    return;
  }
  if (group === "init") {
    process.exitCode = await runInit({ url: values.url, yes: values.yes === true, dryRun: values["dry-run"] === true, tarballs: values.tarballs, dir: command });
    return;
  }
  const logger = consoleLogger();
  const dryRun = values["dry-run"] === true;
  const release2 = values.release ?? process.env.ZHARP_RELEASE;
  const needTarget = (what) => {
    if (!target) fail(`${group} ${command} needs ${what}. See \`zharp --help\`.`);
    if (!(0, import_node_fs11.existsSync)(target)) fail(`${target} does not exist.`);
    return target;
  };
  const connect2 = () => dryRun ? null : resolveConnection({ app: values.app, url: values.url });
  switch (`${group} ${command}`) {
    case "sourcemaps inject": {
      const dir = needTarget("a directory");
      const files = injectDirectory(dir, { include: values.include, exclude: values.exclude, dryRun, logger });
      logger.info(`${dryRun ? "Would inject" : "Injected"} debug IDs into ${files.filter((f) => f.changed).length} file(s); ${files.filter((f) => !f.changed).length} already had one.`);
      return;
    }
    case "sourcemaps upload": {
      const dir = needTarget("a directory");
      const connection = connect2();
      const result = await uploadSourcemaps(dir, connection, {
        release: release2,
        include: values.include,
        exclude: values.exclude,
        deleteAfter: values["delete-after"] === true,
        dryRun,
        logger
      });
      if (result.files === 0) process.exitCode = 1;
      return;
    }
    case "proguard upload": {
      const file = needTarget("the mapping.txt file");
      if (!values.uuid) fail("proguard upload needs --uuid <uuid>: the build UUID the Zharp Gradle plugin put into the app.");
      await uploadProguard(file, values.uuid, connect2(), { release: release2, dryRun, logger });
      return;
    }
    case "dart-symbols upload": {
      const sources = values["no-sources"] ? false : values.sources;
      await uploadDartSymbols(needTarget("the --split-debug-info directory"), connect2(), { release: release2, dryRun, logger, obfuscationMap: values["obfuscation-map"], sources });
      return;
    }
    case "dsym upload": {
      const sources = values["no-sources"] ? false : values.sources;
      await uploadDsyms(needTarget("a .dSYM bundle or a folder of them"), connect2(), { release: release2, dryRun, logger, sources });
      return;
    }
    default:
      fail(`Unknown command "${positionals.join(" ")}". See \`zharp --help\`.`);
  }
}
main(process.argv.slice(2)).catch((error) => {
  console.error(`[zharp] error: ${error instanceof UsageError || error instanceof UploadError || error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
//# sourceMappingURL=cli.js.map