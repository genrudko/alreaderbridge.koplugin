#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
for file in alreaderbridge.koplugin/*.lua; do
  luajit -b "$file" /dev/null
done
luajit tests/test_core.lua
luajit tests/test_positionmap.lua
echo "All portable tests passed"
