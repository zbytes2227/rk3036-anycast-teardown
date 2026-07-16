#!/bin/bash
set -e

DEVICE="YOUR_DONGLE_IP:5555"
BASE=~/rk3036_backup
TS=$(date +%Y%m%d_%H%M%S)

echo "=== Checking device connection ==="
adb -s $DEVICE get-state || { echo "Device not connected!"; exit 1; }

echo "=== Phase 1: Device info ==="
cd "$BASE/device_info"
adb -s $DEVICE exec-out "cat /proc/mtd" > proc_mtd.txt
adb -s $DEVICE exec-out "cat /proc/partitions" > proc_partitions.txt
adb -s $DEVICE exec-out "cat /proc/version" > proc_version.txt
adb -s $DEVICE exec-out "getprop" > getprop_full.txt
adb -s $DEVICE exec-out "cat /proc/cpuinfo" > cpuinfo.txt
adb -s $DEVICE exec-out "ls -la /system/bin" > system_bin_listing.txt
adb -s $DEVICE exec-out "ls -la /system/lib" > system_lib_listing.txt
adb -s $DEVICE exec-out "mount" > mount_table.txt
cat proc_mtd.txt

echo ""
echo "=== Phase 2: Partition dumps (using cat, not dd) ==="
cd "$BASE/adb_dumps"

echo "-- loader (mtdblock0) --"
adb -s $DEVICE exec-out "cat /dev/block/mtdblock0" > loader.bin

echo "-- kernel (mtdblock1) --"
adb -s $DEVICE exec-out "cat /dev/block/mtdblock1" > kernel.bin

echo "-- data (mtdblock2) --"
adb -s $DEVICE exec-out "cat /dev/block/mtdblock2" > data.bin

echo "-- system (mtdblock3) --"
adb -s $DEVICE exec-out "cat /dev/block/mtdblock3" > system.bin

echo "-- misc (mtdblock4) --"
adb -s $DEVICE exec-out "cat /dev/block/mtdblock4" > misc.bin

echo ""
echo "=== Sizes ==="
ls -lh *.bin

echo ""
echo "=== Expected sizes ==="
echo "loader.bin   should be 262144  (256K)"
echo "kernel.bin   should be 4194304 (4.0M)"
echo "data.bin     should be 786432  (768K)"
echo "system.bin   should be ~11403264 (10.9M)"
echo "misc.bin     should be 131072  (128K)"

echo ""
echo "=== Hashing ==="
sha256sum *.bin > SHA256SUMS_${TS}.txt
cat SHA256SUMS_${TS}.txt

echo ""
echo "=== Packing everything into one archive ==="
cd "$BASE"
tar czf rk3036_backup_${TS}.tar.gz adb_dumps device_info
ls -lh rk3036_backup_${TS}.tar.gz

echo ""
echo "=== DONE. Verify sizes above match expected before proceeding. ==="
