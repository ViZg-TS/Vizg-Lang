#!/bin/sh
set -eu

repo_root=${1:-.}
cd "$repo_root"

public_roots="src/root.zig src/project Lib/abi.zig Lib/vizg.zig Lib/vizg.h"

# ViZG owns module discovery/linking, but never a concrete resolution policy.
# Keep filesystem/process APIs and repository fixtures outside the public core.
forbidden='std\.fs|std\.Io|Io\.Dir|\.openFile\(|\.openDir\(|\.realPath|getEnv|test/support|fs_validation_host|fs-validation-host|native_fs_adapter|adapters/native_fs|adapters/fs_module_host'

if grep -R -n -E "$forbidden" $public_roots; then
    echo "concrete module-host policy leaked into the portable core or public ABI" >&2
    exit 1
fi

# Public documentation and headers must not advertise a ViZG-owned resolver.
if grep -n -E 'vizg_(resolve|load)_module|Vizg_(Resolver|ModuleLoader)|VIZG_(RESOLVE|LOAD)_MODULE' Lib/vizg.h; then
    echo "public ABI exposes a module-resolution policy" >&2
    exit 1
fi
