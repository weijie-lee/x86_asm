#!/bin/bash
rm c06_mbr.bin
rm boot.img
nasm -o c06_mbr.bin c06_mbr.asm
dd if=c06_mbr.bin of=boot.img bs=512 count=1
qemu-system-i386 boot.img
