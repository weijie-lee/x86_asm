#!/bin/bash
nasm -o c16_mbr.bin c16_mbr.asm
nasm -o c16_core.bin c16_core.asm
nasm -o c16.bin c16.asm
dd if=/dev/zero of=boot_img count=10000 bs=512
dd if=c16_mbr.bin of=boot_img bs=512 conv=notrunc seek=0
dd if=c16_core.bin of=boot_img bs=512 conv=notrunc seek=1
dd if=c16.bin of=boot_img bs=512 conv=notrunc seek=50


qemu-system-i386 boot_img
