#!/bin/sh
set -e
FASM=${FASM:-fasm}
mkdir -p build
"$FASM" boot.asm build/boot.bin
"$FASM" karnel.asm build/karnel.bin
cat build/boot.bin build/karnel.bin > build/serpentis32.img
# 10 MB so the filesystem at sector 1024 and the users sector after it fit
truncate -s 10M build/serpentis32.img
echo "build/serpentis32.img"
