#!/bin/bash

# Copyright 2017 Linaro Limited
#
# SPDX-License-Identifier: GPL-2.0

PROGNAME=$(basename $0)

set -e		# Accept no failure

# "Sizes" are all in sectors.  Otherwise we call it "bytes".
SECTOR_BYTES=512
EMMC_SIZE=15269888	# 7456 MB in sectors (not hex)

CHUNK_SIZE=524288	# Partition image chuck size in sectors (not hex)
IN_ADDR=0x08000000	# Buffer address for compressed data in from USB (hex)
OUT_ADDR=0x10000000	# Buffer address for uncompressed data for MMC (hex)
EMMC_IO_BYTES=0x100000	# EMMC write buffer size in bytes (hex)

EMMC_DEV=/dev/mmcblk0	# Linux path to main eMMC device on target

# Recommended alignment (in sectors) for partitions other than 1 and 4
PART_ALIGNMENT=2048	# Align at 1MB (512-byte sectors)

# Input files
# The "l-loader.bin" boot loader package
L_LOADER=l-loader.bin
# In case the USB boot loader is different from what we want on eMMC
USB_LOADER=${L_LOADER}	# Must be full l-loader.bin (including first sector)
KERNEL_IMAGE=Image
DEVICE_TREE_BINARY=hi3798cv200-poplar.dtb
# Initial ramdisk is optional; don't define it if it's not set
# INIT_RAMDISK=initrd.img		# a cpio.gz file

# Temporary output files
IMAGE=disk_image	# disk image file
MOUNT=mount		# mount point for disk image; also output directory

# This is the ultimate output file
USB_SIZE=4000000	# A little under 2 GB in sectors
USB_IMG=usb_recovery.img

# content that gets transferred to USB stick

LOADER=loader.bin	# in /boot on target; omits 1st sector of l-loader.bin
INSTALL_SCRIPT=install	# for U-boot to run on the target

###############

function usage() {
	echo >&2
	echo "${PROGNAME}: $@" >&2
	echo >&2
	echo "Usage: ${PROGNAME} <rootfs_archive>" >&2
	echo >&2
	exit 1
}

function suser() {
	echo
	echo To continue, superuser credentials are required.
	sudo -k || nope "failed to kill superuser privilege"
	sudo -v || nope "failed to get superuser privilege"
	SUSER=yes
}

function suser_dd() {
	local dd_args=$*

	sudo dd ${dd_args} status=none || nope "error writing \"$1\""
}

function suser_append() {
	local file=$*

	sudo dd of=${file} oflag=append conv=notrunc status=none ||
	nope "error appending to  \"$file\""
}

function cleanup() {
	[ "${LOOP_MOUNTED}" ] && partition_unmount
	sudo rm -rf ${MOUNT}
	[ "${LOOP_ATTACHED}" ] && loop_detach
	rm -f ${LOADER}
	rm -f ${IMAGE}
}

function nope() {
	if [ $# -gt 0 ]; then
		echo "" >&2
		echo "${PROGNAME}: $@" >&2
		echo "" >&2
	fi
	echo === Poplar recovery image builder ended early ===
	exit 1
}

function howmany() {
	local total_size=$1
	local unit_size=$2

	[ ${unit_size} -gt 0 ] || nope "bad unit_size ${unit_size} in howmany()"
	expr \( ${total_size} + ${unit_size} - 1 \) / ${unit_size}
}

function file_bytes() {
	local filename=$1

	stat --format="%s" ${filename} || nope "unable to stat \"${filename}\""
}

# Make sure we have all our input files, and don't clobber anything
function file_validate() {
	local file

	# Don't kill anything that already exists.  Tell the user
	# that they must be removed instead.
	for i in MOUNT LOADER IMAGE USB_IMG; do
		file=$(eval echo \${$i})
		[ -e ${file} ] &&
		nope "$i file \"$file\" exists it must be removed to continue"
	done

	# Make sure all the input files we need *do* exist and are readable
	for i in L_LOADER USB_LOADER ROOT_FS_ARCHIVE KERNEL_IMAGE \
			DEVICE_TREE_BINARY; do
		file=$(eval echo \${$i})
		[ -f ${file} ] || nope "$i file \"$file\" does not exist"
		[ -r ${file} ] || nope "$i file \"$file\" is not readable"
		[ -s ${file} ] || nope "$i file \"$file\" is empty"
	done
	[ $(file_bytes ${L_LOADER}) -gt ${SECTOR_BYTES} ] ||
	nope "l_loader is much too small"
}

# We use the partition types accepted in /etc/fstab for Linux.
# If valid, the value to use for "parted" is echoed.  Otherwise
# we exit with an error.
function fstype_parted() {
	local fstype=$1

	case ${fstype} in
	vfat)		echo fat32 ;;
	ext4|xfs)	echo ${fstype} ;;
	none)		echo "" ;;
	*)		nope "invalid fstype \"${fstype}\"" ;;
	esac
}

function fstype_mkfs() {
	local fstype=$1

	case ${fstype} in
	vfat)		echo mkfs.fat -F 32 -I ;;
	ext4|xfs)	echo mkfs.${fstype} -q ;;
	none|*)		nope "invalid fstype \"${fstype}\"" ;;
	esac
}

function loop_init() {
	LOOP=$(sudo losetup -f) || nope "unable to find a loop device"
}

function loop_attach() {
	local offset=$1
	local size=$2
	local file=$3

	# Convert to bytes; that's the unit "losetup" wants.  Check
	# for 0 here to avoid non-zero exit status for "expr".
	[ ${offset} -ne 0 ] && offset=$(expr ${offset} \* ${SECTOR_BYTES})
	[ ${size} -gt 0 ] || nope "loop device size must be non-zero"
	size=$(expr ${size} \* ${SECTOR_BYTES})
	sudo losetup ${LOOP} ${file} --offset=${offset} --sizelimit=${size} ||
	nope "unable to set up loop device ${LOOP} on image file ${file}"
	LOOP_ATTACHED=yes
}

function loop_detach() {
	sudo losetup -d ${LOOP} || nope "failed to detach ${LOOP}"
	sudo rm -f ${LOOP}p?    # Linux doesn't remove partitions we created
	unset LOOP_ATTACHED
}

function partition_init() {
	PART_COUNT=0	# Total number of partitions, including extended
	DISK_OFFSET=0	# Next available offset on the disk
}

function partition_define() {
	local part_size=$1
	local part_fstype=$2
	local part_offset=${DISK_OFFSET}	# might change, below
	local part_number=$(expr ${PART_COUNT} + 1)
	local need_boot_record	# By default, no
	local remaining
	local mount_point

	[ ${part_size} -ne 0 ] || nope "partition size must be non-zero"

	[ ${EMMC_SIZE} -gt ${DISK_OFFSET} ] || nope "disk space exhausted"

	remaining=$(expr ${EMMC_SIZE} - ${DISK_OFFSET})
	if [ $# -gt 2 ]; then
		[ "${3:0:1}" != / ] && nope "bad mount point \"$3\""
		mount_point=$3
	fi

	# The first partition is preceded by a 1-sector MBR.  The fourth
	# partition is extended (and accounted for silently below).  All
	# others are preceded by a 1-sector EBR.  In other words, all
	# partitions but 2 and 3 require a sector to hold a boot record.
	if [ ${part_number} -ne 2 -a ${part_number} -ne 3 ]; then
		[ ${remaining} -gt 1 ] || nope "disk space exhausted (extended)"
		remaining=$(expr ${remaining} - 1)
		need_boot_record=yes
	fi
	# A non-positive size (-1) means use the rest of the disk
	if [ ${part_size} -le 0 ]; then
		part_size=${remaining}
	fi
	[ ${part_size} -gt ${remaining} ] &&
	nope "partition too large (${part_size} > ${remaining})"

	# At this point we assume the partition is OK.  Set the
	# partition type, and leave room for a boot record if needed
	if [ ${part_number} -lt 4 ]; then
		PART_TYPE[${part_number}]=primary
	else
		if [ ${part_number} -eq 4 ]; then
			# Fourth partition is extended.  Silently
			# define it to fill what's left of the disk,
			# and then bump the partition number.
			PART_OFFSET[4]=${part_offset}
			PART_SIZE[4]=$(expr ${EMMC_SIZE} - ${part_offset})
			PART_TYPE[4]=extended
			PART_FSTYPE[4]=none

			part_number=5;
		fi
		# The rest are logical partitions, preceded by an EBR
		PART_TYPE[${part_number}]=logical
	fi

	# Reserve space for the MBR or EBR if necessary
	[ "${need_boot_record}" ] && part_offset=$(expr ${part_offset} + 1)

	# Record the partition's offset and size (and final sector)
	PART_OFFSET[${part_number}]=${part_offset}
	PART_SIZE[${part_number}]=${part_size}
	PART_FSTYPE[${part_number}]=${part_fstype}
	if [ "${mount_point}" ]; then
		MOUNT_POINT[${part_number}]=${mount_point}
		[ "${mount_point}" = / ] && PART_ROOT=${part_number}
		[ "${mount_point}" = /boot ] && PART_BOOT=${part_number}
	fi

	# Consume the partition on the disk
	DISK_OFFSET=$(expr ${part_offset} + ${part_size})
	PART_COUNT=${part_number}
}

function partition_check_alignment() {
	local part_number=$1
	local offset=${PART_OFFSET[${part_number}]}
	local prev_number
	local excess
	local recommended

	# We expect partition 1 to start at unaligned offset 1, and extended
	# partition 4 to be one less than an aligned offset so its first
	# logical partition is aligned.
	[ ${part_number} -eq 1 -o ${part_number} -eq 4 ] && return

	# If the partition is aligned we're fine; use "expr" status
	if ! expr ${offset} % ${PART_ALIGNMENT} > /dev/null; then
		return;
	fi

	# Report a warning, and make it helpful.
	prev_number=$(expr ${part_number} - 1)
	[ ${part_number} -eq 5 ] && prev_number=3
	excess=$(expr ${offset} % ${PART_ALIGNMENT})
	recommended=$(expr ${PART_SIZE[${prev_number}]} - ${excess})
	echo Warning: partition ${part_number} is not well aligned.
	echo -n "  Recommend changing partition ${prev_number} size "
	echo to ${recommended} or $(expr ${recommended} + ${PART_ALIGNMENT})
}

# Only one thing to validate right now.  The loader file (without MBR)
# must fit in the first partition.  Warn for non-aligned partitions.
function partition_validate() {
	local loader_bytes=$(expr $(file_bytes ${L_LOADER}) - ${SECTOR_BYTES})
	local loader_part_bytes=$(expr ${PART_SIZE[1]} \* ${SECTOR_BYTES});
	local i

	[ ${loader_bytes} -le ${loader_part_bytes} ] ||
	nope "loader is too big for partition 1" \
		"(${loader_bytes} > ${loader_part_bytes} bytes)"
	for i in $(seq 1 ${PART_COUNT}); do
		partition_check_alignment $i
	done
	# Warn if there's some unused space on the disk; use "expr" status
	if expr ${EMMC_SIZE} - ${DISK_OFFSET} > /dev/null; then
		echo Warning: unused sectors on disk.
		echo -n "  Recommend increasing partition ${PART_COUNT} size "
		echo "to $(expr ${EMMC_SIZE} - ${PART_OFFSET[${PART_COUNT}]})"
		echo
	fi
}

function partition_show() {
	local i
	local ebr_offset

	echo === Using the following disk layout ===

	printf "# %8s %8s %8s %7s %s\n" Start Size Type "FS Type" "Mount Point"
	# The "\055" is just a (leading) dash character (-)
	printf "\055 %8s %8s %8s %7s %s\n" ----- ---- ---- ------- -----------
	printf "* %8u %8u %8s\n" 0 1 MBR
	for i in $(seq 1 ${PART_COUNT}); do
		if [ $i -gt 4 ]; then
			ebr_offset=$(expr ${PART_OFFSET[$i]} - 1)
			printf "* %8u %8u %8s\n" ${ebr_offset} 1 EBR
		fi
		printf "%1u %8u %8u %8s" $i \
			${PART_OFFSET[$i]} ${PART_SIZE[$i]} \
			${PART_TYPE[$i]}
		if [ $i -eq 1 ]; then
			printf " %7s %s" "" "(loader)"
		elif [ $i -ne 4 ]; then
			# No FS type or mount point for the extended partition
			printf " %7s %s" ${PART_FSTYPE[$i]} ${MOUNT_POINT[$i]}
		fi
		echo
	done
	echo "Total EMMC size is ${EMMC_SIZE} ${SECTOR_BYTES}-byte sectors"
}

function partition_mkfs() {
	local part_number=$1
	local mkfs_command=$(fstype_mkfs ${PART_FSTYPE[${part_number}]})

	sudo ${mkfs_command} ${LOOP} ||
	nope "unable to mkfs partition ${part_number}"
}

function partition_mount() {
	sudo mount ${LOOP} ${MOUNT} || nope "unable to mount partition"
	LOOP_MOUNTED=yes
}

function partition_unmount() {
	sudo umount ${LOOP} || nope "unable to unmount partition"
	unset LOOP_MOUNTED
}

# Ask the user to verify whether to continue, for safety
function disk_init() {
	echo
	echo "NOTE: ${LOOP} (backed by image file \"${IMAGE}\") will be"
	echo "      partitioned (i.e., OVERWRITTEN)!"
	echo
	echo "ARE YOU SURE YOU WANT TO OVERWRITE \"${LOOP}\"?"
	echo
	echo -n "Please type \"yes\" to proceed: "
	read -i no x
	[ "${x}" = "yes" ] || nope "aborted by user"
	echo
}

function disk_partition() {
	local i
	local end
	local fstype

	echo === creating partitioned disk image ===

	# Create an empty image file the same size as our target eMMC
	rm -f ${IMAGE} || echo "unable to remove image file \"${IMAGE}\""
	truncate -s $(expr ${EMMC_SIZE} \* ${SECTOR_BYTES}) ${IMAGE} ||
	nope "unable to create empty image file \"${IMAGE}\""
	loop_attach 0 ${EMMC_SIZE} ${IMAGE}

	# Partition our disk image.
	# Note: Do *not* use --script to "parted"; it caused problems...
	{								\
		echo mklabel msdos;					\
		echo unit s;						\
		for i in $(seq 1 ${PART_COUNT}); do			\
			end=$(expr ${PART_OFFSET[$i]} + ${PART_SIZE[$i]} - 1); \
			fstype=$(fstype_parted ${PART_FSTYPE[$i]});	\
			echo -n "mkpart ${PART_TYPE[$i]} ${fstype} ";	\
			echo		"${PART_OFFSET[$i]} ${end}";	\
		done;							\
		[ "${PART_BOOT}" ] && echo "set ${PART_BOOT} boot on";	\
		echo quit;						\
	} | sudo parted ${LOOP} || nope "failed to partition image"
}

function disk_finish() {
	loop_detach
}

function fstab_init() {
	echo "# /etc/fstab: static file system information." |
	suser_dd of=${MOUNT}/etc/fstab
}

function fstab_add() {
	local part_number=$1
	local mount_point
	local fstype

	[ ${part_number} -eq 1 ] && return	# Skip the loader partition
	[ ${part_number} -eq 4 ] && return	# Skip the extended partition

	mount_point=${MOUNT_POINT[${part_number}]}
	fstype=${PART_FSTYPE[${part_number}]}

	# Make sure the mount point exists in the target environment
	sudo mkdir -p ${MOUNT}${mount_point} ||
	nope "failed to create mount point for partition ${part_number}"

	printf "${EMMC_DEV}p%u\t%s\t%s\t%s\n" ${part_number} ${mount_point} \
			${fstype} defaults |
	suser_append ${MOUNT}/etc/fstab
}

# Create the loader file.  It is always in partition 1.
#
# The first sector of l-loader.bin is removed in the loader "loader.bin"
# we maintain.  The boot ROM ignores the first sector, but the "l-loader.bin"
# must be built to contain space for it.  We create "loader.bin" by dropping
# that first sector.  That way "loader.bin" can be written directly into the
# first partition without disturbing the MBR.  We have already verified
# "l-loader" isn't too large for the first partition; it's OK if it's smaller.
function loader_create() {
	dd if=${L_LOADER} of=${LOADER} status=none \
		bs=${SECTOR_BYTES} skip=1 count=${PART_SIZE[1]} ||
	nope "failed to create loader"
}

# Fill the loader partition.  Always partition 1.
function populate_loader() {
	local offset=${PART_OFFSET[1]}
	local size=${PART_SIZE[1]}

	echo "- loader"

	loop_attach ${offset} ${size} ${IMAGE}

	# Just copy in the loader file we already created
	suser_dd if=${LOADER} of=${LOOP} bs=${SECTOR_BYTES} count=${size}

	loop_detach
}

# produce the (expanded) output of a possibly compressed file
function unpack() {
	local file=$1
	local cmd

	case ${file} in
	*.gz|*.tgz)	cmd=zcat ;;
	*.xz|*.txz)	cmd=xzcat ;;
	*.bz|*.tbz)	cmd=bzcat ;;
	*)		cmd=cat ;;
	esac
	${cmd} ${file}
}

function populate_root() {
	local part_number=$1
	local offset=${PART_OFFSET[${part_number}]}
	local size=${PART_SIZE[${part_number}]}

	echo "- root file system"

	loop_attach ${offset} ${size} ${IMAGE}
	partition_mkfs ${part_number}
	partition_mount

	# Extract the root file system tar archive.  The unpack function
	# allows several compressed formats to be used.  Archives from
	# Linaro prefix paths with "binary"; strip that off if it's present.
	unpack ${ROOT_FS_ARCHIVE} |
	sudo tar -C ${MOUNT} -x --transform='s/^binary/./' -f - ||
	nope "failed to populate root"

	# Fill in /etc/fstab
	fstab_init
	for i in $(seq 1 ${PART_COUNT}); do
		fstab_add ${i}
	done

	partition_unmount
	loop_detach
}

# Output the kernel command line arguments.
function kernel_args() {
	echo -n " loglevel=4"
	echo -n " mem=1G"
	echo -n " root=${EMMC_DEV}p${PART_ROOT}"
	echo -n " rootfstype=${PART_FSTYPE[${PART_ROOT}]}"
	echo -n " rootwait"
	echo -n " rw"
	echo -n " earlycon"
	echo
}

# Output the contents of the boot script (extlinux/extlinux.conf)
function bootscript_create() {
	echo "default Buildroot"
	echo "timeout 3"
	echo
	echo "label Buildroot"
	echo "	kernel ../$(basename ${KERNEL_IMAGE})"
	echo "	fdtdir ../"
	[ "${INIT_RAMDISK}" ] && echo "	initrd ../$(basename ${INIT_RAMDISK})"
	echo "	append $(kernel_args)"
}

function populate_boot() {
	local part_number=$1
	local offset=${PART_OFFSET[${part_number}]}
	local size=${PART_SIZE[${part_number}]}

	echo "- /boot"

	loop_attach ${offset} ${size} ${IMAGE}
	partition_mkfs ${part_number}
	partition_mount

	# Save a copy of our loader partition into a file in /boot
	cat ${LOADER} | suser_dd of=${MOUNT}/${LOADER}

	# Now copy in the kernel image, DTB, and extlinux directories
	sudo cp ${KERNEL_IMAGE} ${MOUNT} ||
	nope "failed to save kernel to boot partition"
	sudo cp ${DEVICE_TREE_BINARY} ${MOUNT} ||
	nope "failed to save DTB to boot partition"
	if [ "${INIT_RAMDISK}" ]; then
		sudo cp ${INIT_RAMDISK} ${MOUNT} ||
		nope "failed to save ${INIT_RAMDISK} to boot partition"
	fi
	# sudo cp .../initrd ${MOUNT}	# cpio.gz file
	# Set up the extlinux.conf file
	sudo mkdir -p ${MOUNT}/extlinux ||
	nope "failed to save extlinux directory to boot partition"
	bootscript_create | suser_dd of=${MOUNT}/extlinux/extlinux.conf

	partition_unmount
	loop_detach
}

# Set up for building our USB image.  It will be formatted to have a
# single FAT32 partition.
function image_init() {
	local mkfs_command=$(fstype_mkfs vfat)
	local offset=8	# start the partition at offset 4 KB

	# First partition the disk
	truncate -s $(expr ${USB_SIZE} \* ${SECTOR_BYTES}) ${USB_IMG} ||
	nope "unable to create empty USB image file \"${USB_IMG}\""
	loop_attach 0 ${USB_SIZE} ${USB_IMG}

	# Partition our USB image.
	# Note: Do *not* use --script to "parted"; it caused problems...
	{								\
		echo mklabel msdos;					\
		echo unit s;						\
		echo mkpart primary fat32 ${offset} -1;			\
		echo quit;						\
	} | sudo parted ${LOOP} || nope "failed to partition USB image"
	loop_detach

	# Set up loop device on our sole partition, create a FAT32
	# file system, and mount it
	loop_attach ${offset} $(expr ${USB_SIZE} - ${offset}) ${USB_IMG}

	sudo ${mkfs_command} ${LOOP} || nope "unable to mkfs USB partition"
	partition_mount
}

function image_finish() {
	partition_unmount
	loop_detach
}

function installer_init() {
	echo
	echo === generating installation files ===

	sudo cp /dev/null ${MOUNT}/${INSTALL_SCRIPT}
	cat <<-! | suser_append ${MOUNT}/${INSTALL_SCRIPT}
		# Poplar USB flash drive recovery script
		# Created $(date)
		#
		# Root file system built from:
		#    ${ROOT_FS_ARCHIVE}

		usb start

	!
}

function installer_update() {
	echo "$@" | suser_append ${MOUNT}/${INSTALL_SCRIPT}
}

function installer_add_file() {
	local filename=$1;
	local offset=$(printf "0x%08x" $2)
	local filepath=${MOUNT}/${filename};
	local bytes=$(file_bytes ${filepath});
	local hex_bytes=$(printf "0x%08x" ${bytes})
	local size=$(howmany ${bytes} ${SECTOR_BYTES})
	local hex_size=$(printf "0x%08x" ${size})

	sudo gzip ${filepath}

	installer_update "fatload usb 0:1 ${IN_ADDR} ${filename}.gz"
	installer_update "unzip ${IN_ADDR} ${OUT_ADDR} ${hex_bytes}"
	installer_update "mmc write ${OUT_ADDR} ${offset} ${hex_size}"
	installer_update "echo"
	installer_update ""
}

function installer_finish() {
	sudo cat <<-! | suser_append ${MOUNT}/${INSTALL_SCRIPT}
		echo ============== INSTALLATION IS DONE ===============
		echo (Please remove the USB stick and reset your board)
	!

	echo
	echo === building installer ===
	# Naming the "compiled" script "boot.scr" makes it auto-boot
	sudo mkimage -T script -A arm64 -C none -n 'Poplar Recovery' \
		-d ${MOUNT}/${INSTALL_SCRIPT} ${MOUNT}/${INSTALL_SCRIPT}.scr ||
	nope "failed to build installer image"
}

function save_boot_record() {
	local filename=$1;
	local filepath=${MOUNT}/${filename};
	local offset=$2;	# sectors

	suser_dd if=${IMAGE} of=${filepath} bs=${SECTOR_BYTES} \
			skip=${offset} count=1
	installer_add_file ${filename} ${offset}

}

# Split up partition into chunks; the last may be short.  We do this
# because we must be able to fit an entire file in memory, and we
# plan here for the worst case (though it's unlikely because we
# compress the chunks).
function save_partition() {
	local part_number=$1;
	local part_name="partition${part_number}";
	local offset=${PART_OFFSET[${part_number}]}
	local size=${PART_SIZE[${part_number}]}
	local chunk_size=${CHUNK_SIZE}
	local count=1;
	local limit=$(howmany ${size} ${chunk_size})

	while true; do
		local filename=${part_name}.${count}-of-${limit};
		local filepath=${MOUNT}/${filename}

		if [ ${size} -lt ${chunk_size} ]; then
			chunk_size=${size}
		fi
		echo "- ${filename} (${chunk_size} sectors)"
		suser_dd if=${IMAGE} of=${filepath} bs=${SECTOR_BYTES} \
				skip=${offset} count=${chunk_size}
		installer_add_file ${filename} ${offset}

		count=$(expr ${count} + 1)
		offset=$(expr ${offset} + ${chunk_size})
		# Exit loop when it's all written; use "expr" exit status
		size=$(expr ${size} - ${chunk_size}) || break
	done
}

############################

# Clean up in case we're killed or interrupted in a fairly normal way
trap cleanup EXIT ERR SIGHUP SIGINT SIGQUIT SIGTERM

# Make sure a root file system archive was supplied
[ $# -ne 1 ] && usage "no root file system archive supplied"
ROOT_FS_ARCHIVE=$1

echo
echo ====== Poplar recovery image builder ======
echo

file_validate

partition_init

partition_define 8191    none		# loader
partition_define 262144  vfat /boot
partition_define 3923967 ext4 /
# partition_define 5537791 ext4 /a
# partition_define -1      ext4 /b
partition_validate

partition_show

# Create our loader file (the same size as partition 1)
loader_create

# To go any further we need superuser privilege
suser

loop_init

disk_init
disk_partition
disk_finish

echo === populating loader partition and file systems in image ===

mkdir -p ${MOUNT} || nope "unable to create mount point \"${MOUNT}\""
populate_loader
[ "${PART_ROOT}" ] && populate_root ${PART_ROOT}
[ "${PART_BOOT}" ] && populate_boot ${PART_BOOT}
# We won't populate the other file systems for now

# Set up for building our USB image
image_init

# Initialize the installer script
installer_init

# First, we need "fastboot.bin" on the USB stick for it to be bootable.
sudo cp ${USB_LOADER} ${MOUNT}/fastboot.bin

# Start with the partitioning metadata--MBR and all EBRs
save_boot_record mbr 0
# Partitions 5 and above require an Extended Boot Record
for i in $(seq 5 ${PART_COUNT}); do
	save_boot_record ebr$i.bin $(expr ${PART_OFFSET[$i]} - 1)
done

# Now save off our partition into files used for installation.
for i in $(seq 1 ${PART_COUNT}); do
	# Partition 4 is extended, and is comprised of logical partitions
	[ $i -ne 4 ] && save_partition $i
done

installer_finish

# for building our USB image
image_finish

echo ====== Poplar recovery image builder done! ======

exit 0
