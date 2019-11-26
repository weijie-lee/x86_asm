#!/bin/bash
nasm -o c12_mbr.bin c12_mbr.asm
dd if=/dev/zero of=boot_img count=200 bs=512
dd if=c12_mbr.bin of=boot_img bs=512 conv=notrunc count=1
qemu-system-i386 boot_img
