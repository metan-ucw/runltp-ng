#!/bin/sh

image_path="$1"
revision_a=HEAD
revision_b=20180926

echo "====== installing LTP ${revision_b} ====="

./runltp-ng --backend=qemu:image=${image_path}:password=nevim:system=x86_64 --verbose --install=${revision_b} --run=syscalls --logname=${image_path}-${revision_b}

echo "====== installing LTP ${revision_a} ====="

./runltp-ng --backend=qemu:image=${image_path}:password=nevim:system=x86_64 --verbose --install=${revision_a} --run=syscalls --logname=${image_path}-${revision_a}

