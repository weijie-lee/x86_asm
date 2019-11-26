#!/bin/bash
nasm -o c08_mbr.bin c08_mbr.asm
nasm -o c08.bin c08.asm
dd if=/dev/zero of=boot_img count=200 bs=512
dd if=c08_mbr.bin of=boot_img bs=512 conv=notrunc count=1
dd if=c08.bin of=boot_img bs=512 conv=notrunc seek=100
qemu-system-i386 boot_img
