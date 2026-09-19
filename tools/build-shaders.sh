#!/bin/sh
# Dev-time helper: compile shaders/*.frag into the .qsb bundles the plugin loads.
# Needs Qt's shader baker (Arch: qt6-shadertools, /usr/lib/qt6/bin/qsb). End users do
# not need it: the compiled .qsb files ship with the plugin.
set -e
cd "$(dirname "$0")/../shaders"
QSB=${QSB:-$(command -v qsb || echo /usr/lib/qt6/bin/qsb)}
for f in *.frag; do
  "$QSB" --glsl "300 es,150" --hlsl 50 --msl 12 -o "$f.qsb" "$f"
  echo "built shaders/$f.qsb ($(wc -c < "$f.qsb") bytes)"
done
