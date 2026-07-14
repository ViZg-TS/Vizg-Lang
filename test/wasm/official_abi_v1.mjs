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
  "vizg_project_add_source",
  "vizg_project_analyze_source",
  "vizg_project_create",
  "vizg_project_destroy",
  "vizg_project_finish",
  "vizg_project_respond_external",
  "vizg_project_respond_failure",
  "vizg_project_respond_source",
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
const PAGE_BYTES = 64 * 1024;
const WORKSPACE_BYTES = 8 * 1024 * 1024;
const STATUS_OK = 0;
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

  function writeConfig() {
    const pointer = alloc(28, 4);
    const values = [
      workspace,
      WORKSPACE_BYTES,
      1024 * 1024,
      256,
      4096,
      128,
      65536,
    ];
    values.forEach((value, index) => view.setUint32(pointer + index * 4, value, true));
    return pointer;
  }

  function writeSource(moduleId, logicalName, source, isRoot) {
    const name = writeBytes(logicalName);
    const text = writeBytes(source);
    const pointer = alloc(40, 8);
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
    view.setBigUint64(pointer + 32, 1n, true);
    return pointer;
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
    const summary = alloc(12, 4);
    check(api.vizg_project_result_summary(result, summary), "result_summary");
    const modules = view.getUint32(summary, true);
    const failures = view.getUint8(summary + 4) !== 0;
    if (modules !== expectedModules || failures !== expectedFailures) {
      throw new Error(`unexpected summary: modules=${modules} failures=${failures}`);
    }
    api.vizg_project_result_destroy(result);
    api.vizg_project_destroy(project);
  }

  return {
    alloc,
    createProject,
    finish,
    step,
    view: () => view,
    writeBytes,
    writeSource,
  };
}

function check(status, operation) {
  if (status !== STATUS_OK) throw new Error(`${operation} failed: ${status}`);
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
  check(api.vizg_project_add_source(
    project,
    host.writeSource(1, "main.ts", 'import { value } from "./dep"; export { value };', true),
  ), "multi add_source");
  const request = host.step(project);
  if (request.kind !== STEP_REQUEST) throw new Error("multi did not request dependency");
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
  const name = host.writeBytes("ext");
  const logicalName = host.writeBytes("pkg");
  const exportPointer = host.alloc(20, 4);
  const view = host.view();
  view.setUint32(exportPointer, name.pointer, true);
  view.setUint32(exportPointer + 4, name.length, true);
  view.setUint32(exportPointer + 8, 0, true);
  view.setUint8(exportPointer + 12, 0);
  view.setUint8(exportPointer + 13, 1);
  view.setUint8(exportPointer + 14, 0);
  view.setUint8(exportPointer + 15, 0);
  view.setUint32(exportPointer + 16, 7, true);
  const external = host.alloc(24, 8);
  view.setBigUint64(external, 1n, true);
  view.setUint32(external + 8, logicalName.pointer, true);
  view.setUint32(external + 12, logicalName.length, true);
  view.setUint32(external + 16, exportPointer, true);
  view.setUint32(external + 20, 1, true);
  check(api.vizg_project_respond_external(
    project,
    request.requestId,
    external,
  ), "external respond_external");
  if (host.step(project).kind !== STEP_COMPLETE) throw new Error("external did not complete");
  host.finish(project, 1, false);
}
