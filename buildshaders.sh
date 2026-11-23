#!/bin/sh
set -e

case "$(uname -s)" in
    Linux) exit 0 ;;
    Darwin) executable=ShaderCompiler ;;
    *) executable=ShaderCompiler.exe ;;
esac

folder=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$folder/Rendering/ShaderCompiler/$executable" /P "$folder/shaders" glsl glsl3 glsles glsles3
