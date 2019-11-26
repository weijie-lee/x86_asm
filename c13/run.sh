#!/bin/bash
nasm -o c13_mbr.bin c13_mbr.asm
nasm -o c13_core.bin c13_core.asm
nasm -o c13.bin c13.asm
dd if=/dev/zero of=boot_img count=200 bs=512
dd if=c13_mbr.bin of=boot_img bs=512 conv=notrunc seek=0
dd if=c13_core.bin of=boot_img bs=512 conv=notrunc seek=1
dd if=c13.bin of=boot_img bs=512 conv=notrunc seek=50
dd if=diskdata.txt of=boot_img bs=512 conv=notrunc seek=100
qemu-system-i386 boot_img
