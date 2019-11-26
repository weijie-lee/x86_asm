#!/bin/bash
nasm -o c09_mbr.bin c09_mbr.asm
nasm -o c09_2.bin c09_2.asm
dd if=/dev/zero of=boot_img count=200 bs=512
dd if=c09_mbr.bin of=boot_img bs=512 conv=notrunc count=1
dd if=c09_2.bin of=boot_img bs=512 conv=notrunc seek=100
qemu-system-i386 boot_img
