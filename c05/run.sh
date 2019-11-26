#!/bin/bash
nasm -o c05_mbr.bin c05_mbr.asm
dd if=c05_mbr.bin of=boot.img bs=512 count=1
qemu-system-i386 boot.img
