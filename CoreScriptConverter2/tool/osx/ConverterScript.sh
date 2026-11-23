#!/bin/bash
set -euo pipefail

tool_dir=$(cd "$(dirname "$0")" && pwd)
converter="${1:-$tool_dir/CoreScriptConverter}"
script_dir="$tool_dir/../../../App/script"

cd "$tool_dir"
rm -f "$script_dir/LuaGenCSNew.inl"
"$converter" --rscloc "../rsc.config" --verbose
cd "$script_dir"

if [ ! -s LuaGenCSNew.inl ]; then
    echo "CoreScriptConverter did not generate LuaGenCSNew.inl" >&2
    exit 1
fi

if cmp -s LuaGenCSNew.inl LuaGenCS.inl; then
    rm LuaGenCSNew.inl
else
    mv LuaGenCSNew.inl LuaGenCS.inl
fi
