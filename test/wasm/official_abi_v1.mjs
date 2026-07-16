import { readFile } from "node:fs/promises";

const wasmPath = process.argv[2];
if (!wasmPath) throw new Error("missing WebAssembly module path");

const bytes = await readFile(wasmPath);
const module = await WebAssembly.compile(bytes);
const imports = WebAssembly.Module.imports(module);
if (imports.length !== 0) {
  throw new Error(`unexpected WASM imports: ${JSON.stringify(imports)}`);
}

const expectedExports = [
  "memory",
  "vizg_abi_version",
  "vizg_hir_api_version",
  "vizg_hir_record_at",
  "vizg_hir_summary",
  "vizg_project_add_source",
  "vizg_project_analyze_source",
  "vizg_project_create",
  "vizg_project_destroy",
  "vizg_project_finish",
  "vizg_project_limit_kind",
  "vizg_project_respond_external",
  "vizg_project_respond_failure",
  "vizg_project_respond_source",
  "vizg_project_result_diagnostic",
  "vizg_project_result_edge",
  "vizg_project_result_export",
  "vizg_project_result_import",
  "vizg_project_result_module",
  "vizg_project_result_destroy",
  "vizg_project_result_summary",
  "vizg_project_step",
  "vizg_project_workspace_alignment",
  "vizg_project_workspace_overhead",
].sort();
const actualExports = WebAssembly.Module.exports(module)
  .map((item) => item.name)
  .sort();
if (JSON.stringify(actualExports) !== JSON.stringify(expectedExports)) {
  throw new Error(`unexpected WASM exports: ${actualExports.join(", ")}`);
}

const { exports: api } = await WebAssembly.instantiate(module);
if (api.vizg_abi_version() !== 1) {
  throw new Error(`unexpected ABI version: ${api.vizg_abi_version()}`);
}
if (api.vizg_hir_api_version() !== 1) {
  throw new Error(`unexpected HIR ABI version: ${api.vizg_hir_api_version()}`);
}
const PAGE_BYTES = 64 * 1024;
const WORKSPACE_BYTES = 8 * 1024 * 1024;
const STATUS_OK = 0;
const STATUS_INVALID_ARGUMENT = 1;
const STATUS_LIMIT_EXCEEDED = 4;
const LIMIT_PARSE_DEPTH = 9;
const STEP_COMPLETE = 0;
const STEP_REQUEST = 1;
const FAILURE_NOT_FOUND = 0;
const encoder = new TextEncoder();

function alignForward(value, alignment) {
  return Math.ceil(value / alignment) * alignment;
}

function beginFlow() {
  const requiredPages = Math.ceil((WORKSPACE_BYTES + PAGE_BYTES) / PAGE_BYTES);
  const oldPages = api.memory.grow(requiredPages);
  const alignment = Number(api.vizg_project_workspace_alignment());
  const workspace = alignForward(oldPages * PAGE_BYTES, alignment);
  let cursor = workspace + WORKSPACE_BYTES;
  let view = new DataView(api.memory.buffer);

  function alloc(size, alignment = 8) {
    cursor = alignForward(cursor, alignment);
    const pointer = cursor;
    cursor += size;
    if (cursor > api.memory.buffer.byteLength) {
      const pages = Math.ceil((cursor - api.memory.buffer.byteLength) / PAGE_BYTES);
      api.memory.grow(pages);
      view = new DataView(api.memory.buffer);
    }
    return pointer;
  }

  function writeBytes(value) {
    const data = encoder.encode(value);
    const pointer = alloc(data.length, 1);
    new Uint8Array(api.memory.buffer, pointer, data.length).set(data);
    return { pointer, length: data.length };
  }

  function writeConfigAt(pointer, overrides = {}) {
    const values = [
      overrides.workspace ?? workspace,
      overrides.workspaceLength ?? WORKSPACE_BYTES,
      1024 * 1024,
      16 * 1024 * 1024,
      256,
      1024,
      1024,
      4096,
      128,
      65536,
    ];
    values.forEach((value, index) => view.setUint32(pointer + index * 4, value, true));
    return pointer;
  }

  function writeConfig(overrides = {}) {
    return writeConfigAt(alloc(40, 4), overrides);
  }

  function writeSource(moduleId, logicalName, source, isRoot) {
    const name = writeBytes(logicalName);
    const text = writeBytes(source);
    const pointer = alloc(32, 8);
    view.setBigUint64(pointer, BigInt(moduleId), true);
    view.setUint32(pointer + 8, name.pointer, true);
    view.setUint32(pointer + 12, name.length, true);
    view.setUint32(pointer + 16, text.pointer, true);
    view.setUint32(pointer + 20, text.length, true);
    view.setUint32(pointer + 24, 1, true);
    view.setUint8(pointer + 28, isRoot ? 1 : 0);
    view.setUint8(pointer + 29, 0);
    view.setUint8(pointer + 30, 0);
    view.setUint8(pointer + 31, 0);
    return pointer;
  }

  function writeExternal(logicalName, exportName) {
    const name = writeBytes(exportName);
    const moduleName = writeBytes(logicalName);
    const exportPointer = alloc(20, 4);
    view.setUint32(exportPointer, name.pointer, true);
    view.setUint32(exportPointer + 4, name.length, true);
    view.setUint32(exportPointer + 8, 0, true);
    view.setUint8(exportPointer + 12, 1);
    view.setUint8(exportPointer + 13, 1);
    view.setUint8(exportPointer + 14, 0);
    view.setUint8(exportPointer + 15, 0);
    view.setUint32(exportPointer + 16, 7, true);
    const pointer = alloc(24, 8);
    view.setBigUint64(pointer, 1n, true);
    view.setUint32(pointer + 8, moduleName.pointer, true);
    view.setUint32(pointer + 12, moduleName.length, true);
    view.setUint32(pointer + 16, exportPointer, true);
    view.setUint32(pointer + 20, 1, true);
    return { pointer, exportPointer };
  }

  function createProject() {
    const config = writeConfig();
    const out = alloc(4, 4);
    view.setUint32(out, 0, true);
    check(api.vizg_project_create(config, out), "project_create");
    const project = view.getUint32(out, true);
    if (project === 0) throw new Error("project_create returned null");
    return project;
  }

  function step(project) {
    const pointer = alloc(64, 8);
    new Uint8Array(api.memory.buffer, pointer, 64).fill(0);
    check(api.vizg_project_step(project, pointer), "project_step");
    return {
      kind: view.getUint32(pointer, true),
      requestId: view.getBigUint64(pointer + 8, true),
    };
  }

  function finish(project, expectedModules, expectedFailures) {
    const resultOut = alloc(4, 4);
    view.setUint32(resultOut, 0, true);
    check(api.vizg_project_finish(project, resultOut), "project_finish");
    const result = view.getUint32(resultOut, true);
    if (result === 0) throw new Error("project_finish returned null");
    const summary = alloc(28, 4);
    check(api.vizg_project_result_summary(result, summary), "result_summary");
    const modules = view.getUint32(summary, true);
    const partial = view.getUint8(summary + 20) !== 0;
    const projectErrors = view.getUint8(summary + 23) !== 0;
    const failures = view.getUint8(summary + 24) !== 0;
    if (modules !== expectedModules || partial !== expectedFailures || projectErrors || failures !== expectedFailures) {
      throw new Error(`unexpected summary: modules=${modules} partial=${partial} projectErrors=${projectErrors} failures=${failures}`);
    }
    api.vizg_project_destroy(project);
  }

  return {
    alloc,
    createProject,
    finish,
    step,
    workspace,
    view: () => view,
    writeBytes,
    writeConfig,
    writeConfigAt,
    writeExternal,
    writeSource,
  };
}

function check(status, operation) {
  if (status !== STATUS_OK) throw new Error(`${operation} failed: ${status}`);
}

function expectInvalid(operation, callback) {
  let status;
  try {
    status = callback();
  } catch (error) {
    throw new Error(`${operation} trapped`, { cause: error });
  }
  if (status !== STATUS_INVALID_ARGUMENT) {
    throw new Error(`${operation} returned ${status}, expected INVALID_ARGUMENT`);
  }
}

function expectNoTrap(operation, callback) {
  try {
    callback();
  } catch (error) {
    throw new Error(`${operation} trapped`, { cause: error });
  }
}

// Host-controlled structures and workspaces must be range-checked before the
// implementation dereferences them. These calls must return INVALID_ARGUMENT
// rather than trapping the WebAssembly instance.
{
  const host = beginFlow();
  const config = host.writeConfig();
  const out = host.alloc(4, 4);
  host.view().setUint32(out, 0x12345678, true);
  const end = api.memory.buffer.byteLength;

  expectInvalid("create null config", () => api.vizg_project_create(0, out));
  if (host.view().getUint32(out, true) !== 0x12345678) {
    throw new Error("create null config modified its output");
  }
  expectInvalid("create null output", () => api.vizg_project_create(config, 0));
  expectInvalid("create out-of-bounds config", () => api.vizg_project_create(end, out));
  expectInvalid("create near-end config", () => api.vizg_project_create(end - 2, out));
  expectInvalid("create overflowing config", () => api.vizg_project_create(0xfffffffc, out));

  const misalignedConfig = host.alloc(40, 4) + 1;
  host.writeConfigAt(misalignedConfig);
  expectInvalid("create misaligned config", () => api.vizg_project_create(misalignedConfig, out));
  expectInvalid("create out-of-bounds output", () => api.vizg_project_create(config, end));
  expectInvalid("create near-end output", () => api.vizg_project_create(config, end - 2));
  expectInvalid("create misaligned output", () => api.vizg_project_create(config, host.alloc(8, 4) + 1));

  const configWorkspace = host.view().getUint32(config, true);
  expectInvalid("create config-output alias", () => api.vizg_project_create(config, config));
  if (host.view().getUint32(config, true) !== configWorkspace) {
    throw new Error("create config-output alias modified its config");
  }

  const configInWorkspace = host.writeConfigAt(host.workspace);
  expectInvalid("create config-workspace alias", () => api.vizg_project_create(configInWorkspace, out));
  host.writeConfigAt(config);
  expectInvalid("create output-workspace alias", () => api.vizg_project_create(config, host.workspace));

  const invalidWorkspace = host.writeConfig({ workspace: end });
  expectInvalid("create out-of-bounds workspace", () => api.vizg_project_create(invalidWorkspace, out));
  const nearEndWorkspace = host.writeConfig({ workspace: end - 4 });
  expectInvalid("create near-end workspace", () => api.vizg_project_create(nearEndWorkspace, out));
  const misalignedWorkspace = host.writeConfig({ workspace: host.workspace + 1 });
  expectInvalid("create misaligned workspace", () => api.vizg_project_create(misalignedWorkspace, out));
  const overflowingWorkspace = host.writeConfig({ workspace: 0xfffffffc, workspaceLength: 8 });
  expectInvalid("create overflowing workspace", () => api.vizg_project_create(overflowingWorkspace, out));
}

{
  const host = beginFlow();
  const project = host.createProject();
  check(api.vizg_project_add_source(
    project,
    host.writeSource(1, "single.ts", "export const value = 1;", true),
  ), "single add_source");
  if (host.step(project).kind !== STEP_COMPLETE) throw new Error("single did not complete");
  host.finish(project, 1, false);
}

{
  const host = beginFlow();
  const project = host.createProject();
  const source = `const value = ${"!".repeat(1025)}value;`;
  check(api.vizg_project_add_source(
    project,
    host.writeSource(1, "deep.ts", source, true),
  ), "parse-depth add_source");
  const step = host.alloc(64, 8);
  const status = api.vizg_project_step(project, step);
  if (status !== STATUS_LIMIT_EXCEEDED) {
    throw new Error(`parse-depth step returned ${status}, expected LIMIT_EXCEEDED`);
  }
  const kind = api.vizg_project_limit_kind(project);
  if (kind !== LIMIT_PARSE_DEPTH) {
    throw new Error(`parse-depth limit kind ${kind}, expected ${LIMIT_PARSE_DEPTH}`);
  }
  api.vizg_project_destroy(project);
}

// Every handle-taking export and every host output validates the complete
// pointer range, alignment, and workspace exclusion before observing state.
{
  const host = beginFlow();
  const project = host.createProject();
  let end = api.memory.buffer.byteLength;
  const scratch = host.alloc(128, 8);

  expectInvalid("add_source null handle", () => api.vizg_project_add_source(0, scratch));
  expectInvalid("add_source null input", () => api.vizg_project_add_source(project, 0));
  expectInvalid("add_source out-of-bounds input", () => api.vizg_project_add_source(project, end));
  expectInvalid("add_source near-end input", () => api.vizg_project_add_source(project, end - 2));
  expectInvalid("add_source misaligned input", () => api.vizg_project_add_source(project, scratch + 1));
  expectInvalid("add_source workspace input", () => api.vizg_project_add_source(project, host.workspace));

  const invalidLimitHandles = [0, end, end - 1, scratch + 1];
  for (const handle of invalidLimitHandles) {
    expectNoTrap(`limit_kind hostile handle ${handle}`, () => {
      const kind = api.vizg_project_limit_kind(handle);
      if (kind !== 0) throw new Error(`returned ${kind}, expected NONE`);
    });
  }

  let source = host.writeSource(1, "hostile.ts", "export const value = 1;", true);
  host.view().setUint32(source + 16, end, true);
  expectInvalid("add_source out-of-bounds nested source", () => api.vizg_project_add_source(project, source));
  host.view().setUint32(source + 16, 0xfffffffe, true);
  host.view().setUint32(source + 20, 4, true);
  expectInvalid("add_source overflowing nested source", () => api.vizg_project_add_source(project, source));
  host.view().setUint32(source + 16, host.workspace, true);
  host.view().setUint32(source + 20, 1, true);
  expectInvalid("add_source workspace nested source", () => api.vizg_project_add_source(project, source));

  source = host.writeSource(1, "hostile.ts", "export const value = 1;", true);
  check(api.vizg_project_add_source(project, source), "hostile add_source after invalid inputs");

  end = api.memory.buffer.byteLength;
  expectInvalid("step null handle", () => api.vizg_project_step(0, scratch));
  expectInvalid("step null output", () => api.vizg_project_step(project, 0));
  expectInvalid("step out-of-bounds output", () => api.vizg_project_step(project, end));
  expectInvalid("step near-end output", () => api.vizg_project_step(project, end - 2));
  expectInvalid("step misaligned output", () => api.vizg_project_step(project, scratch + 1));
  expectInvalid("step workspace output", () => api.vizg_project_step(project, host.workspace));
  if (host.step(project).kind !== STEP_COMPLETE) {
    throw new Error("hostile project did not complete after invalid step outputs");
  }

  expectInvalid("finish null handle", () => api.vizg_project_finish(0, scratch));
  expectInvalid("finish null output", () => api.vizg_project_finish(project, 0));
  expectInvalid("finish out-of-bounds output", () => api.vizg_project_finish(project, end));
  expectInvalid("finish near-end output", () => api.vizg_project_finish(project, end - 2));
  expectInvalid("finish misaligned output", () => api.vizg_project_finish(project, scratch + 1));
  expectInvalid("finish workspace output", () => api.vizg_project_finish(project, host.workspace));

  const resultOut = host.alloc(4, 4);
  check(api.vizg_project_finish(project, resultOut), "hostile finish after invalid outputs");
  const result = host.view().getUint32(resultOut, true);
  if (result === 0) throw new Error("hostile finish returned null");

  const accessors = [
    ["result_summary", (handle, output) => api.vizg_project_result_summary(handle, output)],
    ["result_module", (handle, output) => api.vizg_project_result_module(handle, 0, output)],
    ["result_diagnostic", (handle, output) => api.vizg_project_result_diagnostic(handle, 0, output)],
    ["result_edge", (handle, output) => api.vizg_project_result_edge(handle, 0, output)],
    ["result_import", (handle, output) => api.vizg_project_result_import(handle, 0, output)],
    ["result_export", (handle, output) => api.vizg_project_result_export(handle, 0, output)],
  ];
  end = api.memory.buffer.byteLength;
  for (const [name, call] of accessors) {
    expectInvalid(`${name} null handle`, () => call(0, scratch));
    expectInvalid(`${name} invalid handle`, () => call(end, scratch));
    expectInvalid(`${name} null output`, () => call(result, 0));
    expectInvalid(`${name} out-of-bounds output`, () => call(result, end));
    expectInvalid(`${name} near-end output`, () => call(result, end - 2));
    expectInvalid(`${name} misaligned output`, () => call(result, scratch + 1));
    expectInvalid(`${name} workspace output`, () => call(result, host.workspace));
  }

  const summary = host.alloc(28, 4);
  check(api.vizg_project_result_summary(result, summary), "hostile valid summary");
  if (host.view().getUint32(summary, true) !== 1) {
    throw new Error("hostile valid summary lost project state");
  }

  expectNoTrap("destroy null handle", () => api.vizg_project_destroy(0));
  expectNoTrap("destroy out-of-bounds handle", () => api.vizg_project_destroy(end));
  expectNoTrap("destroy near-end handle", () => api.vizg_project_destroy(end - 1));
  expectNoTrap("destroy misaligned handle", () => api.vizg_project_destroy(scratch + 1));
  api.vizg_project_destroy(project);
}

{
  const host = beginFlow();
  const project = host.createProject();
  check(api.vizg_project_add_source(
    project,
    host.writeSource(1, "main.ts", 'import { value } from "./dep"; export { value };', true),
  ), "multi add_source");
  const request = host.step(project);
  if (request.kind !== STEP_REQUEST) throw new Error("multi did not request dependency");
  let end = api.memory.buffer.byteLength;
  const scratch = host.alloc(64, 8);
  expectInvalid("respond_source null handle", () => api.vizg_project_respond_source(0, request.requestId, scratch));
  expectInvalid("respond_source null input", () => api.vizg_project_respond_source(project, request.requestId, 0));
  expectInvalid("respond_source out-of-bounds input", () => api.vizg_project_respond_source(project, request.requestId, end));
  expectInvalid("respond_source near-end input", () => api.vizg_project_respond_source(project, request.requestId, end - 2));
  expectInvalid("respond_source misaligned input", () => api.vizg_project_respond_source(project, request.requestId, scratch + 1));
  expectInvalid("respond_source workspace input", () => api.vizg_project_respond_source(project, request.requestId, host.workspace));

  let hostileSource = host.writeSource(2, "dep.ts", "export const value = 1;", false);
  end = api.memory.buffer.byteLength;
  host.view().setUint32(hostileSource + 16, end, true);
  expectInvalid("respond_source out-of-bounds nested source", () => api.vizg_project_respond_source(project, request.requestId, hostileSource));
  host.view().setUint32(hostileSource + 16, 0xfffffffe, true);
  host.view().setUint32(hostileSource + 20, 4, true);
  expectInvalid("respond_source overflowing nested source", () => api.vizg_project_respond_source(project, request.requestId, hostileSource));
  host.view().setUint32(hostileSource + 16, host.workspace, true);
  host.view().setUint32(hostileSource + 20, 1, true);
  expectInvalid("respond_source workspace nested source", () => api.vizg_project_respond_source(project, request.requestId, hostileSource));

  check(api.vizg_project_respond_source(
    project,
    request.requestId,
    host.writeSource(2, "dep.ts", "export const value = 1;", false),
  ), "multi respond_source");
  if (host.step(project).kind !== STEP_COMPLETE) throw new Error("multi did not complete");
  host.finish(project, 2, false);
}

{
  const host = beginFlow();
  const project = host.createProject();
  check(api.vizg_project_add_source(
    project,
    host.writeSource(1, "missing.ts", 'import "./absent";', true),
  ), "missing add_source");
  const request = host.step(project);
  if (request.kind !== STEP_REQUEST) throw new Error("missing did not request dependency");
  const end = api.memory.buffer.byteLength;
  const scratch = host.alloc(16, 8);
  expectInvalid("respond_failure null handle", () => api.vizg_project_respond_failure(
    0,
    request.requestId,
    FAILURE_NOT_FOUND,
  ));
  expectInvalid("respond_failure out-of-bounds handle", () => api.vizg_project_respond_failure(
    end,
    request.requestId,
    FAILURE_NOT_FOUND,
  ));
  expectInvalid("respond_failure near-end handle", () => api.vizg_project_respond_failure(
    end - 2,
    request.requestId,
    FAILURE_NOT_FOUND,
  ));
  expectInvalid("respond_failure misaligned handle", () => api.vizg_project_respond_failure(
    scratch + 1,
    request.requestId,
    FAILURE_NOT_FOUND,
  ));
  expectInvalid("respond_failure invalid kind", () => api.vizg_project_respond_failure(
    project,
    request.requestId,
    99,
  ));
  check(api.vizg_project_respond_failure(
    project,
    request.requestId,
    FAILURE_NOT_FOUND,
  ), "missing respond_failure");
  if (host.step(project).kind !== STEP_COMPLETE) throw new Error("missing did not complete");
  host.finish(project, 1, true);
}

{
  const host = beginFlow();
  const project = host.createProject();
  check(api.vizg_project_add_source(
    project,
    host.writeSource(1, "external.ts", 'import { ext } from "pkg"; export { ext };', true),
  ), "external add_source");
  const request = host.step(project);
  if (request.kind !== STEP_REQUEST) throw new Error("external did not request dependency");
  let end = api.memory.buffer.byteLength;
  const scratch = host.alloc(64, 8);
  expectInvalid("respond_external null handle", () => api.vizg_project_respond_external(0, request.requestId, scratch));
  expectInvalid("respond_external null input", () => api.vizg_project_respond_external(project, request.requestId, 0));
  expectInvalid("respond_external out-of-bounds input", () => api.vizg_project_respond_external(project, request.requestId, end));
  expectInvalid("respond_external near-end input", () => api.vizg_project_respond_external(project, request.requestId, end - 2));
  expectInvalid("respond_external misaligned input", () => api.vizg_project_respond_external(project, request.requestId, scratch + 1));
  expectInvalid("respond_external workspace input", () => api.vizg_project_respond_external(project, request.requestId, host.workspace));

  let external = host.writeExternal("pkg", "ext");
  end = api.memory.buffer.byteLength;
  host.view().setUint32(external.pointer + 8, end, true);
  expectInvalid("respond_external out-of-bounds logical name", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint32(external.pointer + 8, 0xfffffffe, true);
  host.view().setUint32(external.pointer + 12, 4, true);
  expectInvalid("respond_external overflowing logical name", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint32(external.pointer + 8, host.workspace, true);
  host.view().setUint32(external.pointer + 12, 1, true);
  expectInvalid("respond_external workspace logical name", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));

  external = host.writeExternal("pkg", "ext");
  host.view().setUint32(external.pointer + 16, end, true);
  expectInvalid("respond_external out-of-bounds exports", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint32(external.pointer + 16, end - 2, true);
  expectInvalid("respond_external near-end exports", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint32(external.pointer + 16, scratch + 1, true);
  expectInvalid("respond_external misaligned exports", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint32(external.pointer + 16, host.workspace, true);
  expectInvalid("respond_external workspace exports", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint32(external.pointer + 16, 4, true);
  host.view().setUint32(external.pointer + 20, 0xffffffff, true);
  expectInvalid("respond_external overflowing export count", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));

  external = host.writeExternal("pkg", "ext");
  host.view().setUint32(external.exportPointer, end, true);
  expectInvalid("respond_external out-of-bounds export name", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint32(external.exportPointer, 0xfffffffe, true);
  host.view().setUint32(external.exportPointer + 4, 4, true);
  expectInvalid("respond_external overflowing export name", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint32(external.exportPointer, host.workspace, true);
  host.view().setUint32(external.exportPointer + 4, 1, true);
  expectInvalid("respond_external workspace export name", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));

  external = host.writeExternal("pkg", "ext");
  host.view().setUint8(external.exportPointer + 12, 0);
  expectInvalid("respond_external zero namespace", () => api.vizg_project_respond_external(project, request.requestId, external.pointer));
  host.view().setUint8(external.exportPointer + 12, 1);
  check(api.vizg_project_respond_external(
    project,
    request.requestId,
    external.pointer,
  ), "external respond_external");
  if (host.step(project).kind !== STEP_COMPLETE) throw new Error("external did not complete");
  host.finish(project, 1, false);
}
