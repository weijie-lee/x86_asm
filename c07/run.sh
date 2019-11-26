#!/bin/bash
rm c07_mbr.bin
rm boot.img
nasm -o c07_mbr.bin c07_mbr.asm
dd if=c07_mbr.bin of=boot.img bs=512 count=1
qemu-system-i386 boot.img
