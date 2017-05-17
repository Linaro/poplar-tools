# Building Poplar System Recovery Media From Source

The instructions that follow describe the process for creating a USB
flash drive suitable for use in recovering a Poplar system from a
"bricked" state.  The USB memory stick must be at least 8GB.

## Gather required sources

First you'll gather the source code and other materials required to
package a USB recovery device.

### Step 1: Make sure you have needed tools installed.  This list may well
  grow, but at least you'll need the following:

```shell
      sudo apt-get update
      sudo apt-get install device-tree-compiler libssl-dev u-boot-tools
```

### Step 2: Set up the working directory.

```shell
  mkdir -p ~/src/poplar
  cd ~/src/poplar
  TOP=$(pwd)
```

### Step 3: Download a root file system image to use.  These are available from
  Linaro.  An example is "linaro-stretch-developer-20170511-60.tar.gz",
  which is (or was) available here:
    http://snapshots.linaro.org/debian/images/stretch/developer-arm64/latest/
  Note that these images change regularly, so the image you get will
  be different from this.  If you download this file by some means
  other than "wget" shown below, please ensure it gets place in the
  "recovery" directory created here.

```shell
    mkdir ${TOP}/recovery
    wget -P ${TOP}/recovery \
        http://snapshots.linaro.org/debian/images/stretch/developer-arm64/latest/linaro-stretch-developer-20170511-60.tar.gz
```

### Step 4: Get the source code:

```shell
  cd ${TOP}
  git clone https://github.com/linaro/poplar-tools.git
  git clone https://github.com/linaro/poplar-l-loader.git
  git clone https://github.com/linaro/poplar-arm-trusted-firmware.git
  git clone https://github.com/linaro/poplar-u-boot.git
  git clone https://github.com/linaro/poplar-linux.git
```

### Step 5: Set up branches to use, and make sure everything is clean:

```shell
    cd ${TOP}/poplar-linux
    git checkout -b latest origin/latest

    cd ${TOP}/poplar-u-boot
    git checkout -b latest origin/latest

    cd ${TOP}/poplar-arm-trusted-firmware
    git checkout -b latest origin/latest

    cd ${TOP}/poplar-l-loader
    git checkout -b latest origin/latest
```

### Step 6: Prepare for building.  Almost everything is aarch64, but one item
  (l-loader.bin) must be built for 32-bit ARM.  Set up environment
  variables to represent the two cross-compiler toolchains you'll
  be using.

```shell
    CROSS_32=arm-linux-gnueabi-
    CROSS_64=aarch64-linux-gnu-
```

  If you don't already have ARM 32- and 64-bit toochains installed,
  they are available from Linaro.
    https://releases.linaro.org/components/toolchain/binaries/latest/
  Install the "aarch64-linux-gnu" and "arm-linux-gnueabi" packages
  for your system.  (Depending on where you install them, you may
  need to specify absolute paths for the values of CROSS_32 and
  CROSS_64.)

  Large builds (e.g Linux) are sped up considerably by running
  "make" with multiple concurrent jobs.  The command below sets
  JOBCOUNT to something reasonable to benefit from this.

```shell
    JOBCOUNT=$(grep ^processor /proc/cpuinfo | wc -w)
```

## Build everything

### Step 1: Build U-Boot.  The result of this process will be a file
  "u-boot.bin" that will be incorporated into a "FIP" file created
  for ARM Trusted Firmware code.

```
    # This produces one output file, which is used when building ARM
    # Trusted Firmware, next:
    #       u-boot.bin
    cd ${TOP}/poplar-u-boot
    make distclean
    make CROSS_COMPILE=${CROSS_64} poplar_defconfig
    make CROSS_COMPILE=${CROSS_64} -j ${JOBCOUNT}
```

### Step 2: Build ARM Trusted Firmware components.  

This will create "bl1.bin" and "fip.bin", both of which will be incorporated into the image 
created for "l-loader". The FIP file packages files "bl2.bin" and
"bl31.bin" built here along with "u-boot.bin" built earlier into
"fip.bin".  ARM Trusted Firmware keeps its output in a directory
"build"; you'll create a symlink to that in our output directory,
to keep things together.

```shell
    # This produces two output files, which are used when building
    # "l-loader", next:
    #       build/poplar/debug/bl1.bin
    #       build/poplar/debug/fip.bin
    cd ${TOP}/poplar-arm-trusted-firmware
    make distclean
    make CROSS_COMPILE=${CROSS_64} all fip DEBUG=1 PLAT=poplar SPD=none \
		       BL33=${TOP}/poplar-u-boot/u-boot.bin
```

### Step 3: Build "l-loader"

First you'll gather the two ARM Trusted Firmware
components you built into the "atf" directory.  Note that "l-loader"
is a 32-bit executable, so you need to use a different tool chain.

```shell
    # This produces one output file, which is used in building the
    # USB flash drive:
    #       l-loader.bin
    cd ${TOP}/poplar-l-loader
    cp ${TOP}/poplar-arm-trusted-firmware/build/poplar/debug/bl1.bin atf/
    cp ${TOP}/poplar-arm-trusted-firmware/build/poplar/debug/fip.bin atf/
    make clean
    make CROSS_COMPILE=${CROSS_32}
```

### Step 4: Build Linux.  

The result of this process will be two files: "Image"
contains the kernel image; and "hi3798cv200-poplar.dtb" containing
the flattened device tree file (device tree binary).

```shell
    # This produces two output files, which are used when building
    # the USB flash drive image:
    #       arch/arm64/boot/Image
    #       arch/arm64/boot/dts/hisilicon/hi3798cv200-poplar.dtb
    rm -rf ${TOP}/recovery/root
    mkdir -p ${TOP}/recovery/root
    cd ${TOP}/poplar-linux
    make distclean
    make ARCH=arm64 CROSS_COMPILE="${CROSS_64}" defconfig
    mkdir -p ${TOP}/recovery/root/boot
    make ARCH=arm64 CROSS_COMPILE="${CROSS_64}" \
    			INSTALL_PATH=${TOP}/recovery/root/boot \
    			INSTALL_MOD_PATH=${TOP}/recovery/root \
    			INSTALL_DTBS_PATH=${TOP}/recovery/root/boot \
			all install modules_install dtbs_install \
			-j ${JOBCOUNT} > make.out 2>&1 &

#    			INSTALL_FW_PATH=${TOP}/recovery/root/lib/firmware \
#    			INSTALL_HDR_PATH=${TOP}/recovery/root/usr \
#			firmware_install headers_install
```

### Step 5: Gather the required components you built above

This is done in order to create the Poplar USB drive recovery image.

```shell
    cd ${TOP}/recovery
    cp ${TOP}/poplar-tools/poplar_recovery_builder.sh .
    cp ${TOP}/poplar-l-loader/l-loader.bin .
    cp ${TOP}/poplar-linux/arch/arm64/boot/Image .
    cp ${TOP}/poplar-linux/arch/arm64/boot/dts/hisilicon/hi3798cv200-poplar.dtb .
```

### Step 6: Build an image to save to a USB flash drive for Poplar recovery.
  
You need to supply the root file system image you downloaded
earlier (whose name will be different from what's shown below).

```shell
    # This produces one output file, which is written to a USB flash drive:
    #       usb_recovery.img
    bash ./poplar_recovery_builder.sh \
		    linaro-stretch-developer-20170511-60.tar.gz
```

## Prepare to replace the contents of a USB flash drive with the output of the build.

### Step 1: First you need to identify your USB flash drive.  

THIS IS VERY IMPORTANT. This will COMPLETELY ERASE the contents of whatever
  device you specify here.  So be sure you get it right.**

 - Insert the USB flash drive into your host system.
 - Identify your USB device:

```shell
	grep . /sys/class/block/sd?/device/model
```

 If you recognize the model name as your USB flash device, then
 you know which "sd" device to use.  Here's an example:

```shell
	/sys/class/block/sdc/device/model:Patriot Memory
	                     ^^^
```

I had a Patriot Memory USB flash drive, and the device name
I'll want is "/dev/sdc" (based on "sdc" above).  Record this name:

```shell
	USBDISK=/dev/sdc	# Make sure this is *your* device
```

### Step 2: Unmount Flash Drive

Unmount anything on that USB flash drive that might have been automatically mounted when you inserted it.

```shell
    mount | grep ${USBDISK} | awk '{print $1}' | xargs sudo umount
```

### Step 3: Overwrite the USB drive you have inserted with the built image.

#### You will need superuser access. This is where you write your disk image to the USB flash drive.

```shell
    sudo dd if=usb_recovery.img of=${USBDISK}
```

#### Eject the USB flash drive,

```shell
    sudo eject ${USBDISK}
```

#### Remove the USB flash drive from your host system

## Run the recovery on the Poplar board

- Next you'll put the USB flash drive on the Poplar board to boot
  from it.  The Poplar board should be powered off.  You should have
  a cable from the Poplar's micro USB based serial port to your host
  system so you can connect and observe activity on the serial port.
  For me, the board console shows up as /dev/ttyUSB0 when the USB
  cable is connected.  The serial port runs at 115200 baud.  I use
  this command to see what's on the console:
  
```shell
      screen /dev/ttyUSB0 115200
```

- There are a total of 4 USB connectors on the Poplar board.  Two
  are USB 2.0 ports, they're stacked on top of each other.  Insert
  the USB memory stick into one of these two.

- Next you will be powering on the board, but you need to interrupt
  the automated boot process.  To do this, be prepared to enter
  control-C, perhaps repeatedly, in the serial console window until
  you find the boot process has stopped.

- Power on the Poplar board, and interrupt its automated boot with
  control-C.

- Now enter the following commands in the Poplar serial console

```shell
    usb reset
    fatload usb 0:1 ${scriptaddr} install.scr
    source ${scriptaddr}
```

  It will take about 5-10 minutes to complete writing out the contents
  of the disk.  When this is done, the board will automatically
  reset.  The result should look a bit like this:

```shell
    ---------------------------
    | ## Executing script at 32000000
    | reading mbr.gz
    | 159 bytes read in 15 ms (9.8 KiB/s)
    | Uncompressed size: 512 = 0x200
    |
    | MMC write: dev # 0, block # 0, count 1 ... 1 blocks written: OK
    |
    | reading partition1.1-of-1.gz
    | 223851 bytes read in 32 ms (6.7 KiB/s)
    | Uncompressed size: 4193792 = 0x3FFE00
    |
    | MMC write: dev # 0, block # 1, count 8191 ... 8191 blocks written: OK
    |          . . .
```

- When this process completes, remove your USB memory stick from the
  Poplar board and reset it.  You can reset it in one of three ways:
  press the reset button; power the board off and on again; or run
  this command in the serial console window:

```shell
    reset
```

  At this point, Linux should automatically boot from the eMMC.

You have now booted your Poplar board with open source code that you
have built yourself.
