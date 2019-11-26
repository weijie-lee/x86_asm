#!/bin/bash
rm *.bin boot_img
nasm -o c17_mbr.bin c17_mbr.asm
nasm -o c17_core.bin c17_core.asm
nasm -o c17_1.bin c17-1.asm
nasm -o c17_2.bin c17-2.asm

dd if=/dev/zero of=boot_img bs=512 count=500

dd if=c17_mbr.bin of=boot_img bs=512 conv=notrunc seek=0
dd if=c17_core.bin of=boot_img bs=512 conv=notrunc seek=1
dd if=c17_1.bin of=boot_img bs=512 conv=notrunc seek=50
dd if=c17_2.bin of=boot_img bs=512 conv=notrunc seek=100

qemu-system-i386 boot_img
