#!/bin/bash
nasm -o c18_mbr.bin c18_mbr.asm
nasm -o c18_core.bin c18_core.asm
dd if=/dev/zero of=boot_img bs=512 count=500
dd if=c18_mbr.bin of=boot_img bs=512 conv=notrunc seek=0
dd if=c18_core.bin of=boot_img bs=512 conv=notrunc seek=1
qemu-system-i386 boot_img
