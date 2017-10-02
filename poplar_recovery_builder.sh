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
SUB_ADDR=0x07800000	# Buffer address for sub-installer scripts

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
############
ANDROID_BOOT_IMAGE=boot.img
ANDROID_SYSTEM_IMAGE=system.img
ANDROID_CACHE_IMAGE=cache.img
ANDROID_USER_DATA_IMAGE=userdata.img

# Temporary output files
MOUNT=mount		# mount point for disk image; also output directory

# Directory in which copies of output files are created
RECOVERY=recovery_files

# This is the ultimate output file
USB_SIZE=4000000	# A little under 2 GB in sectors

# content that gets transferred to USB stick

LOADER=${RECOVERY}/loader.bin	# omits 1st sector of l-loader.bin
INSTALL_SCRIPT=install	# for U-boot to run on the target

TEMPFILE=$(mktemp -p .)

###############

function cleanup() {
	[ "${MOUNTED}" ] && partition_unmount
	rm -rf ${MOUNT}
	rm -f ${LOADER}
	rm -f ${TEMPFILE}
}

# Clean up in case we're killed or interrupted in a fairly normal way
trap cleanup EXIT ERR SIGHUP SIGINT SIGQUIT SIGTERM

function nope() {
	if [ $# -gt 0 ]; then
		echo "" >&2
		echo "${PROGNAME}: $@" >&2
		echo "" >&2
	fi
	echo === Poplar recovery image builder ended early ===
	exit 1
}

function usage() {
	echo >&2
	echo "${PROGNAME}: $@" >&2
	echo >&2
	echo "Usage: ${PROGNAME} <arg>" >&2
	echo >&2
	echo "  for a Linux image, <arg> is a root file system tar archive" >&2
	echo "  if <arg> is \"android\" an Android image is built" >&2
	echo >&2
	exit 1
}

function parseargs() {
	# Make sure a single argument was supplied
	[ $# -lt 1 ] && usage "no arguments supplied"
	[ $# -ne 1 ] && usage "missing argument"

	INPUT_FILES="L_LOADER USB_LOADER"
	INPUT_FILES="${INPUT_FILES}"
	if [ "$1" = "android" ]; then
		IMAGE_TYPE=Android
		INPUT_FILES="${INPUT_FILES} ANDROID_BOOT_IMAGE"
		INPUT_FILES="${INPUT_FILES} ANDROID_SYSTEM_IMAGE"
		INPUT_FILES="${INPUT_FILES} ANDROID_CACHE_IMAGE"
		INPUT_FILES="${INPUT_FILES} ANDROID_USER_DATA_IMAGE"
	else
		IMAGE_TYPE=Linux
		ROOT_FS_ARCHIVE=$1
		INPUT_FILES="${INPUT_FILES} KERNEL_IMAGE"
		INPUT_FILES="${INPUT_FILES} DEVICE_TREE_BINARY"
		INPUT_FILES="${INPUT_FILES} ROOT_FS_ARCHIVE"
	fi
}

function suser() {
	echo
	echo To continue, superuser credentials are required.
	sudo -k || nope "failed to kill superuser privilege"
	sudo -v || nope "failed to get superuser privilege"
	SUSER=yes
}

function suser_cat() {
	local file=$1

	sudo dd of=${file} status=none || nope "error writing \"${file}\""
}

function suser_append() {
	local file=$*

	sudo dd of=${file} oflag=append conv=notrunc status=none ||
	nope "error appending to  \"$file\""
}

function howmany() {
	local total_size=$1
	local unit_size=$2

	[ ${unit_size} -gt 0 ] || nope "bad unit_size ${unit_size} in howmany()"
	expr \( ${total_size} + ${unit_size} - 1 \) / ${unit_size}
}

function file_bytes() {
	local filename=$1

	stat --dereference --format="%s" ${filename} ||
	nope "unable to stat \"${filename}\""
}

# Make sure we have all our input files, and don't clobber anything
function file_validate() {
	local file
	local i

	# Don't kill anything that already exists; just say it .
	# that they must be removed instead.
	[ -e ${LOADER} ] &&
	nope "\"$LOADER\" exists it must be removed to continue"

	# Make sure all the input files we need *do* exist and are readable
	for i in ${INPUT_FILES} ; do
		file=$(eval echo \${$i})
		[ -f ${file} ] || nope "$i file \"$file\" does not exist"
		[ -r ${file} ] || nope "$i \"$file\" is not readable"
		[ -s ${file} ] || nope "$i \"$file\" is empty"
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

# Certain partitions are special, and for those we record their number
function map_description() {
	local part_number=$1
	local description=$2

	case ${description} in
	/)			PART_ROOT=${part_number} ;;
	/boot)			PART_BOOT=${part_number} ;;
	android_boot)		PART_ANDROID_BOOT=${part_number} ;;
	android_system)		PART_ANDROID_SYSTEM=${part_number} ;;
	android_cache)		PART_ANDROID_CACHE=${part_number} ;;
	android_user_data)	PART_ANDROID_USER_DATA=${part_number} ;;
	*)			;;	# We don't care about any others
	esac;
}

function partition_init() {
	PART_COUNT=0	# Total number of partitions, including extended
	DISK_OFFSET=0	# Next available offset on the disk
}

function partition_define() {
	local part_size=$1
	local part_fstype=$2
	local description=$3
	local part_offset=${DISK_OFFSET}	# might change, below
	local part_number=$(expr ${PART_COUNT} + 1)
	local part_type
	local remaining

	[ ${part_size} -eq 0 ] && nope "partition size must be non-zero"

	# The first partition is preceded by a 1-sector MBR.  The fourth
	# partition is extended, and we associate the EBR in its
	# first block with the first logical partition contained
	# within it.  Logical partitions are preceded by a 1-sector
	# EBR.  In other words, we require an initial sector for all
	# partitions but 2, 3, and 4 to hold a boot record.
	if [ ${part_number} -eq 1 -o ${part_number} -gt 4 ]; then
		part_offset=$(expr ${part_offset} + 1)
	fi
	[ ${EMMC_SIZE} -gt ${part_offset} ] || nope "disk space exhausted"
	remaining=$(expr ${EMMC_SIZE} - ${part_offset})

	# A non-positive size (-1) means use the rest of the disk
	if [ ${part_size} -le 0 ]; then
		part_size=${remaining}
	fi
	[ ${part_size} -gt ${remaining} ] &&
	nope "partition too large (${part_size} > ${remaining})"

	case ${description} in
	/)			PART_ROOT=${part_number}
				PART_TYPE[${PART_ROOT}]=0x83
				PART_FSTYPE[${PART_ROOT}]=ext4
				;;
	/boot)			PART_BOOT=${part_number}
				PART_TYPE[${PART_BOOT}]=0xef
				PART_FSTYPE[${PART_BOOT}]=vfat
				;;
	loader)			[ ${part_number} -eq 1 ] ||
				nope "only partition 1 can be extended"
				PART_TYPE[1]=0xf0
				PART_FSTYPE[1]=none
				;;
	android_boot)		PART_ANDROID_BOOT=${part_number}
				PART_TYPE[${PART_ANDROID_BOOT}]=0xda
				PART_FSTYPE[${PART_ANDROID_BOOT}]=none
				;;
	android_system)		PART_ANDROID_SYSTEM=${part_number}
				PART_TYPE[${PART_ANDROID_SYSTEM}]=0x83
				PART_FSTYPE[${PART_ANDROID_SYSTEM}]=ext4
				;;
	android_cache)		PART_ANDROID_CACHE=${part_number}
				PART_TYPE[${PART_ANDROID_CACHE}]=0x83
				PART_FSTYPE[${PART_ANDROID_CACHE}]=ext4
				;;
	android_user_data)	PART_ANDROID_USER_DATA=${part_number}
				PART_TYPE[${PART_ANDROID_USER_DATA}]=0x83
				PART_FSTYPE[${PART_ANDROID_USER_DATA}]=ext4
				;;
	extended)		[ ${part_number} -eq 4 ] ||
				nope "only partition 4 can be extended"
				PART_TYPE[4]=0x0f
				PART_FSTYPE[4]=none
				;;
	esac;
	PART_OFFSET[${part_number}]=${part_offset}
	PART_SIZE[${part_number}]=${part_size}
	DESCRIPTION[${part_number}]=${description}

	# Consume the partition on the disk (except for extended)
	if [ ${part_number} -ne 4 ]; then
		DISK_OFFSET=$(expr ${part_offset} + ${part_size})
	fi
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

	printf "# %8s %8s %8s %7s %s\n" Start Size Type "FS Type" "Description"
	# The "\055" is just a (leading) dash character (-)
	printf "\055 %8s %8s %8s %7s %s\n" ----- ---- ---- ------- -----------
	printf "* %8u %8u %8s\n" 0 1 MBR
	for i in $(seq 1 ${PART_COUNT}); do
		if [ $i -gt 4 ]; then
			ebr_offset=$(expr ${PART_OFFSET[$i]} - 1)
			printf "* %8u %8u %8s\n" ${ebr_offset} 1 EBR
		fi
		printf "%1u %8u %8u %8s" $i \
			${PART_OFFSET[$i]} ${PART_SIZE[$i]} ${PART_TYPE[$i]}
		# No FS type or description for the extended partition
		[ $i -ne 444 ] &&
			printf " %7s %s" ${PART_FSTYPE[$i]} ${DESCRIPTION[$i]}
		echo
	done
	echo "Total EMMC size is ${EMMC_SIZE} ${SECTOR_BYTES}-byte sectors"
}

function partition_mount() {
	local part_number=$1
	local part_name="${RECOVERY}/partition${part_number}"
	local bytes=$(expr ${PART_SIZE[${part_number}]} \* ${SECTOR_BYTES})
	local mkfs_command=$(fstype_mkfs ${PART_FSTYPE[${part_number}]})

	# The file system will be backed by an image file
	trunc_file ${part_name} ${bytes}

	${mkfs_command} ${part_name} ||
	nope "unable to mkfs partition on partition ${part_number}"

	mkdir -p ${MOUNT} || nope "unable to create mount point"
	sudo mount ${part_name} ${MOUNT} || nope "unable to mount partition"
	MOUNTED=yes
}

function partition_unmount() {
	sudo umount ${MOUNT} || nope "unable to unmount partition"
	unset MOUNTED
}

function trunc_file() {
	local name=$1
	local bytes=$2

	# First discard any previous content
	truncate -s 0 ${name} || nope "unable to truncate file \"${name}\""
	# Now set it to the specified size
	truncate -s ${bytes} ${name} ||
	nope "unable to extend \"${name}\" to ${bytes} bytes"
}

function disk_partition() {
	local i

	echo === creating partitioned disk MBR and EBRs ===

	# Start by setting the temp file to be the size of the whole EMMC
	trunc_file ${TEMPFILE} $(expr ${EMMC_SIZE} \* ${SECTOR_BYTES})

	# Now partition the temp_file as an image.
	{
		echo "label: dos"
		echo "label-id: 0x78f9d0f7"
		for i in $(seq 1 ${PART_COUNT}); do
			echo -n "$i:"
			echo -n " start=${PART_OFFSET[$i]}"
			echo -n " size=${PART_SIZE[$i]}"
			echo -n " type=${PART_TYPE[$i]}"
			[ $i -eq ${PART_BOOT=${part_number}} ] &&
				echo -n " bootable"
			echo ""
		done
		echo "write"
	} | sfdisk --quiet --no-reread --no-tell-kernel ${TEMPFILE}
}

function fstab_init() {
	sudo mkdir -p ${MOUNT}/etc
	echo "# /etc/fstab: static file system information." |
	suser_cat ${MOUNT}/etc/fstab
}

function fstab_add() {
	local part_number=$1
	local mount_point
	local fstype

	# Skip the loader and extended partitions
	[ ${part_number} -eq 1 -o ${part_number} -eq 4 ] && return

	mount_point=${DESCRIPTION[${part_number}]}
	fstype=${PART_FSTYPE[${part_number}]}

	# Make sure the mount point exists in the target environment
	sudo mkdir -p ${MOUNT}/${mount_point} ||
	nope "failed to create mount point for partition ${part_number}"

	printf "${EMMC_DEV}p%u\t%s\t%s\t%s\n" ${part_number} ${mount_point} \
			${fstype} defaults | suser_append ${MOUNT}/etc/fstab
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
		bs=${SECTOR_BYTES} skip=1 || nope "failed to create loader"
}

function populate_begin() {
	local part_number=$1
	local fstype=${PART_FSTYPE[${part_number}]}

	[ "${fstype}" == none ] && nope "no need for populate_begin"

	# Extract the root file system tar archive.  The unpack function
	# allows several compressed formats to be used.  Archives from
	# Linaro prefix paths with "binary"; strip that off if it's present.
	partition_mount ${part_number}
}

function populate_end() {
	local part_number=$1
	local fstype=${PART_FSTYPE[${part_number}]}
	local part_name="${RECOVERY}/partition${part_number}"

	[ "${fstype}" == none ] && nope "no need for populate_end"

	partition_unmount
}

# Populate a partition using "raw" data from a file
function populate_image() {
	local part_number=$1
	local source_image=$2
	local part_name="${RECOVERY}/partition${part_number}"

	# NOTE:  Partition space beyond the source image is *not* zeroed.
	# We may wish to reconsider this at some point.
	dd status=none if=${source_image} of=${part_name} bs=${SECTOR_BYTES} ||
	nope "failed to populate image for partition ${part_number}"
}

# Populate a partition using an Android sparse file system image
function populate_simage() {
	local part_number=$1
	local source_image=$2
	local part_name="${RECOVERY}/partition${part_number}"

	# Expand the sparse image.
	simg2img ${source_image} ${part_name} ||
	nope "unable to expand ${source_image}"
}

# Fill the loader partition.  Always partition 1.
function populate_loader() {
	local part_number=1	# Not dollar-1, just 1

	# Just image copy the loader file we already created.
	echo "- loader"
	loader_create
	populate_image ${part_number} ${LOADER}
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

	echo "- root file system"

	populate_begin ${part_number}

	unpack ${ROOT_FS_ARCHIVE} |
	sudo tar -C ${MOUNT} -x --transform='s/^binary/./' -f - ||
	nope "failed to populate root"

	# Fill in /etc/fstab
	fstab_init
	for i in $(seq 1 ${PART_COUNT}); do
		fstab_add ${i}
	done

	populate_end ${part_number}
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
	echo -n " mmz=ddr,0,0,60M"	# Currently required for SDK kernels
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

	echo "- /boot"

	populate_begin ${part_number}

	# Save a copy of our loader partition into a file in /boot
	sudo cp ${LOADER} ${MOUNT}/$(basename ${LOADER})

	if [ "${PART_ROOT}" ]; then
		# Now copy in the kernel image, DTB, and extlinux directories
		sudo cp ${KERNEL_IMAGE} ${MOUNT} ||
		nope "failed to save kernel to boot partition"
		sudo mkdir -p ${MOUNT}/hisilicon ||
		nope "failed to create hisilicon DTB directory"
		sudo cp ${DEVICE_TREE_BINARY} ${MOUNT}/hisilicon ||
		nope "failed to save DTB to boot partition"
		if [ "${INIT_RAMDISK}" ]; then
			cp ${INIT_RAMDISK} ${MOUNT} ||
			nope "failed to save ${INIT_RAMDISK} to boot partition"
		fi
		# Set up the extlinux.conf file
		sudo mkdir -p ${MOUNT}/extlinux ||
		nope "failed to save extlinux directory to boot partition"
		bootscript_create | suser_append ${MOUNT}/extlinux/extlinux.conf
	fi

	populate_end ${part_number}
}

function populate_android_boot() {
	local part_number=$1

	echo "- Android boot"
	populate_image ${part_number} ${ANDROID_BOOT_IMAGE}
}

function populate_android_system() {
	local part_number=$1

	echo "- Android system"
	populate_simage ${part_number} ${ANDROID_SYSTEM_IMAGE}
}

function populate_android_cache() {
	local part_number=$1

	echo "- Android cache"
	populate_simage ${part_number} ${ANDROID_CACHE_IMAGE}
}

function populate_android_user_data() {
	local part_number=$1

	echo "- Android user data"
	populate_simage ${part_number} ${ANDROID_USER_DATA_IMAGE}
}

function installer_update() {
	echo "$@" >> ${CURRENT_SCRIPT}
}

function installer_compile() {
	local description="$@"

	mkimage -T script -A arm64 -C none -n "${description}" \
		-d ${CURRENT_SCRIPT} ${CURRENT_SCRIPT}.scr ||
	nope "failed to compile image for \"${CURRENT_SCRIPT}\""
}

function installer_init() {
	echo
	echo === generating installation files ===

	mkdir -p ${RECOVERY} || nope "unable to create \"${RECOVERY}\""
	CURRENT_SCRIPT=${RECOVERY}/${INSTALL_SCRIPT}
	cp /dev/null ${CURRENT_SCRIPT}

	installer_update "# Poplar ${IMAGE_TYPE} recovery U-Boot script"
	installer_update "# Created $(date)"
	installer_update ""
	if [ "${IMAGE_TYPE}" = Linux ]; then
		installer_update "# Root file system built from:"
		installer_update "#    ${ROOT_FS_ARCHIVE}"
		installer_update ""
	fi
}

function installer_init_sub_script() {
	local sub=$1; shift
	local description="$@"
	local new_script=${RECOVERY}/${INSTALL_SCRIPT}-${sub}

	# Add commands to the top-level script to source the one we
	# will be created.  It will be compiled into a binary file
	# with the extension ".scr" when we're done creating it
	installer_update "# ${description}"
	installer_update "tftp ${SUB_ADDR} ${new_script}.scr"
	installer_update "source ${SUB_ADDR}"
	installer_update ""

	# Switch to the sub-script file and give it a short header
	CURRENT_SCRIPT=${new_script}
	cp /dev/null ${CURRENT_SCRIPT}
	installer_update "# ${description}"
	installer_update ""
}

function installer_add_file() {
	local filename=$1;
	local hex_disk_offset=$(printf "0x%08x" $2)
	local bytes=$(file_bytes ${filename});
	local hex_bytes=$(printf "0x%08x" ${bytes})
	local size=$(howmany ${bytes} ${SECTOR_BYTES})
	local hex_size=$(printf "0x%08x" ${size})

	gzip ${filename}

	installer_update "tftp ${IN_ADDR} ${filename}.gz"
	installer_update "unzip ${IN_ADDR} ${OUT_ADDR} ${hex_bytes}"
	installer_update "mmc write ${OUT_ADDR} ${hex_disk_offset} ${hex_size}"
	installer_update "echo"
	installer_update ""
}

function installer_finish_sub_script() {
	# Compile the sub-script into <filename>.scr, then switch
	# back to the top-level sript.
	installer_compile $(basename ${CURRENT_SCRIPT})

	CURRENT_SCRIPT=${RECOVERY}/${INSTALL_SCRIPT}
}

function installer_finish() {
	installer_update "echo ============ INSTALLATION IS DONE ============="
	installer_update "echo (Please reset your board)"

	echo
	echo === building installer ===
	installer_compile "Poplar Recovery"

	unset CURRENT_SCRIPT
}

function save_boot_record() {
	local part_number=$1;
	local filename
	local offset

	if [ ${part_number} -eq 0 ]; then
		filename=${RECOVERY}/mbr.bin
		offset=0
	elif [ ${part_number} -gt 4 ]; then
		filename=${RECOVERY}/ebr${part_number}.bin
		offset=$(expr ${PART_OFFSET[$part_number]} - 1)
	else
		nope "bad boot record number ${part_number}"
	fi

	dd status=none if=${TEMPFILE} of=${filename} bs=${SECTOR_BYTES} \
			skip=${offset} count=1

	installer_add_file ${filename} ${offset}
}

function save_layout() {
	local i

	installer_init_sub_script layout "Partition layout (MBR and EBRs)"

	save_boot_record 0	# MBR
	# Partitions 5 and above require an Extended Boot Record
	for i in $(seq 5 ${PART_COUNT}); do
		save_boot_record $i
	done

	installer_finish_sub_script
}

# Split up partition into chunks; the last may be short.  We do this
# because we must be able to fit an entire file in memory, and we
# plan here for the worst case (though it's unlikely because we
# compress the chunks).
function save_partition() {
	local part_number=$1
	local part_name=${RECOVERY}/partition${part_number}
	local part_offset=${PART_OFFSET[${part_number}]}
	local offset=0
	local size=${PART_SIZE[${part_number}]}
	local chunk_size=${CHUNK_SIZE}
	local count=1;
	local limit=$(howmany ${size} ${chunk_size})
	local desc="Partition ${part_number} (${DESCRIPTION[${part_number}]})"

	if [ ! -e "${part_name}" ]; then
		echo "Skipping partition ${part_number}"
		return
	fi

	installer_init_sub_script $(basename ${part_name}) "${desc}"

	while true; do
		local filename=${part_name}.${count}-of-${limit};
		local disk_offset=$(expr ${part_offset} + ${offset})

		if [ ${size} -lt ${chunk_size} ]; then
			chunk_size=${size}
		fi
		echo "- ${filename} (${chunk_size} sectors)"
		dd status=none if=${part_name} of=${filename} \
			bs=${SECTOR_BYTES} skip=${offset} count=${chunk_size}
		installer_add_file ${filename} ${disk_offset}

		count=$(expr ${count} + 1)
		offset=$(expr ${offset} + ${chunk_size})
		# Exit loop when it's all written; use "expr" exit status
		size=$(expr ${size} - ${chunk_size}) || break
	done

	installer_finish_sub_script

	# done with the original file, so delete it
	rm -f ${part_name}
}

############################

parseargs "$@"

echo
echo ====== Poplar recovery image builder ======
echo

file_validate

partition_init
partition_define 8191   none loader
partition_define 262144 vfat /boot
if [ "${IMAGE_TYPE}" = Android ]; then
	partition_define 81919  none android_boot
	partition_define -1     none extended
	partition_define  2097151 ext4 android_system
	partition_define  2097151 ext4 android_cache
	partition_define 10723328 ext4 android_user_data
else
	partition_define 3999743 ext4 /
	# We'll not use the rest (10999809 sectors) for now
	# partition_define -1  none extended
	# partition_define 5500927 ext4 /a
	# partition_define -1      ext4 /b
fi
partition_validate
partition_show

suser

# Ready to start creating
disk_partition
installer_init
save_layout

echo === populating loader partition and file systems in image ===

# Create the loader file and save it to its partition
populate_loader

# Save a copy of  "fastboot.bin" so it can be placed on a USB stick,
# allowing it to be bootable for de-bricking.
cp ${USB_LOADER} ${RECOVERY}/fastboot.bin

# Populate the boot file system and save it to its partition
populate_boot ${PART_BOOT}

# Now populate the rest of the partitions; we save them below
if [ "${IMAGE_TYPE}" = Android ]; then
	[ "${PART_ANDROID_BOOT}" ] &&
		populate_android_boot ${PART_ANDROID_BOOT}
	[ "${PART_ANDROID_SYSTEM}" ] &&
		populate_android_system ${PART_ANDROID_SYSTEM}
	[ "${PART_ANDROID_CACHE}" ] &&
		populate_android_cache ${PART_ANDROID_CACHE}
	[ "${PART_ANDROID_USER_DATA}" ] &&
		populate_android_user_data ${PART_ANDROID_USER_DATA}
else
	[ "${PART_ROOT}" ] && populate_root ${PART_ROOT}
	# We won't populate the other file systems for now
fi

# Save off our partition into files used for installation.
for i in $(seq 1 ${PART_COUNT}); do
	# Partition 4 is extended, and is comprised of logical partitions
	[ $i -ne 4 ] && save_partition $i
done

installer_finish

echo ====== Poplar recovery builder is done! ======
echo ""
echo ====== Recovery files can be found in \"${RECOVERY}\" ======

exit 0
