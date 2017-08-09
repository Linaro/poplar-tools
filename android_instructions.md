# Building and booting Android on Poplar

[![Creative Commons Licence](https://licensebuttons.net/l/by-sa/4.0/88x31.png)](http://creativecommons.org/licenses/by-sa/4.0/)

The instructions that follow describe the process for creating a USB
flash drive suitable for use in loading Android onto a Poplar board.

## Gather required sources

First you'll gather the source code and other materials required to
package a USB recovery device. These instructions assume you are
using Linux based OS on your host machine.

### Step 1: Make sure you have needed tools installed

This list may well grow, but at least you'll need the following:

```shell
      sudo apt-get update
      sudo apt-get upgrade
      sudo apt-get install openjdk-8-jdk flex
      sudo apt-get install device-tree-compiler libssl-dev u-boot-tools
```

### Step 2: Set up the working directory.

```shell
  mkdir -p ~/src/poplar
  cd ~/src/poplar
  TOP=$(pwd)
```

### Step 3: Get the source code for the boot loader components.
  The "latest" branch in these repositories should always point to a
  known working copy of the code.

```shell
  cd ${TOP}
  git clone https://github.com/linaro/poplar-tools.git -b latest
  git clone https://github.com/linaro/poplar-l-loader.git -b latest
  git clone https://github.com/linaro/poplar-arm-trusted-firmware.git -b latest
  git clone https://github.com/linaro/poplar-u-boot.git -b latest

### Step 4: Get the HiSilicon SDK source code
  We'll use the "master" branch in the HiSilicon Linux SDK and the
  SDK Linux kernel trees:

```shell
  cd ${TOP}
  git clone ssh://git@dev-private-git.linaro.org/aspen/staging/linux-sdk.git
  git clone ssh://git@dev-private-git.linaro.org/aspen/staging/linux.git
```
  Note that the "linux-sdk" tree is the bulk of the SDK code.  The
  Linux kernel code has been extracted from that tree and put in a
  separate repository, "linux.git".

### Step 5: Get the source code for Android with Poplar support.
  We will use Android AOSP version 7.1.1_r3 as a base.  (This will
  take at least an hour, probably more.)

```shell
  cd ${TOP}
  mkdir android
  cd android

  repo init -u https://android.googlesource.com/platform/manifest.git \
		-b android-7.1.1_r3
  repo sync -j8
```
  We now need to download code to add Poplar support.  We'll use the
  "master" branch here as well.

```shell
  cd ${TOP}
  cd android
  mkdir device/hisilicon
  cd device/hisilicon
  git clone \
    ssh://git@dev-private-git.linaro.org/aspen/staging/device/linaro/poplar.git
```
### Step 6: Prepare for building the boot code
  Almost everything uses aarch64, but one item (l-loader.bin) must
  be built for 32-bit ARM.  Set up environment variables to
  represent the two cross-compiler toolchains you'll be using.

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
  CROSS_64, above.)

## Build everything

### Step 1: Build U-Boot.
  The result of this process will be a file "u-boot.bin" that will
  be incorporated into a FIP file created for ARM Trusted Firmware code.

```
    # This produces one output file, which is used when building ARM
    # Trusted Firmware, next:
    #       u-boot.bin
    cd ${TOP}/poplar-u-boot
    make distclean
    make CROSS_COMPILE=${CROSS_64} poplar_defconfig
    make CROSS_COMPILE=${CROSS_64}
```

### Step 2: Build ARM Trusted Firmware components.
  The result of this process will be two files "bl1.bin" and
  "fip.bin", which will be incorporated into the image created for
  "l-loader" in the next step. The FIP file packages files "bl2.bin"
  and "bl31.bin" (built here) along with "u-boot.bin" (built earlier).

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
  This requires the two ARM Trusted Firmware components you built
  earlier.  So start by copying them into the "atf" directory.  Note
  that "l-loader" is a 32-bit executable, so you need to use a
  different tool chain.

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

### Step 4: Build Linux, using the SDK environment
  The result of this process will be two files: "Image" contains the
  kernel image; and "hi3798cv200.dtb" containing the flattened
  device tree file (device tree binary).  The device tree file will
  need to be renamed "hi3798cv200-poplar.dtb" below.  A Linux build
  is sped up considerably by running "make" with multiple concurrent
  jobs.  JOBCOUNT is set below to something reasonable to benefit
  from this.

```shell
    # This produces two output files, which are used when building
    # the USB flash drive image.  Both paths are shown relative to
    # this output directory for brevity:
    #    out/hi3798cv200/hi3798cv2dmo/obj64/source/kernel/linux-4.4.y
    #       .../arch/arm64/boot/Image
    #       .../arch/arm64/boot/dts/hisilicon/hi3798cv200-poplar.dtb
    JOBCOUNT=$(grep ^processor /proc/cpuinfo | wc -w)
    cd ${TOP}/linux-sdk
    source env.sh
    make -j ${JOBCOUNT} linux
```

  Record where the Linux output files are for later:
```shell
    cd ${TOP}/linux-sdk
    cd out/hi3798cv200/hi3798cv2dmo/obj64/source/kernel/linux-4.4.y
    LINUX_OUT=$(pwd)
```

### Step 5: Build Android, using the Linux we just built
  First we need to copy the prebuilt kernel and device tree files
  into place in the Android tree.  (Note the DTB is renamed.)

```shell
    cd ${TOP}/android
    mkdir device/hisilicon/poplar-kernel
    cp ${LINUX_OUT}/arch/arm64/boot/Image \
		device/hisilicon/poplar-kernel
    cp ${LINUX_OUT}/arch/arm64/boot/dts/hisilicon/hi3798cv200.dtb \
		device/hisilicon/poplar-kernel/hi3798cv200-poplar.dtb

```

  And now, we need to build Android.  This takes a very long time,
  and consumes lots of memory.  If you don't have more than 8GB of
  memory you should run this command first and hope for the best.

```shell
      export JACK_SERVER_VM_ARGUMENTS="-Xmx4g"
```

  To build Android (after limiting memory use if necessary)::

```shell
    cd ${TOP}/android
    source build/envsetup.sh
    lunch poplar-eng
    make -j ${JOBCOUNT}
```

### Step 6: Gather the required components you built above
  First gather the files that will be required to create the Poplar
  USB drive recovery image.  The root file system image should
  already have been placed in the "recovery" directory.

```shell
    cd ${TOP}
    mkdir recovery
    cd recovery
    cp ${TOP}/poplar-tools/poplar_recovery_builder.sh .
    cp ${TOP}/poplar-l-loader/l-loader.bin .
    cp ${TOP}/android/out/target/product/poplar/boot.img .
    cp ${TOP}/android/out/target/product/poplar/system.img .
    cp ${TOP}/android/out/target/product/poplar/cache.img .
    cp ${TOP}/android/out/target/product/poplar/userdata.img .
```

### Step 7: Build an image to save to a USB flash drive for Poplar recovery.
  You need to supply the root file system image you downloaded
  earlier (whose name will be different from what's shown below).

```shell
    # This produces one output file, which is written to a USB flash drive:
    #       usb_recovery.img
    bash ./poplar_recovery_builder.sh android
```

## Prepare to replace the contents of a USB flash drive with the output of the build.

### Step 1: First you need to identify your USB flash drive.
  THIS IS VERY IMPORTANT. This will COMPLETELY ERASE the contents of
  whatever device you specify here.  So be sure you get it right.

  Insert the USB flash drive into your host system, and identify
  your USB device:

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

### Step 2: Overwrite the USB drive you have inserted with the built image.

  You will need superuser access.  This is where you write your disk
  image to the USB flash drive.

```shell
    sudo dd if=usb_recovery.img of=${USBDISK}
```

  Eject the USB flash drive,

```shell
    sudo eject ${USBDISK}
```

  Remove the USB flash drive from your host system

## Run the recovery on the Poplar board
  Next you'll put the USB flash drive on the Poplar board to boot
  from it.

- The Poplar board should be powered off.  You should have a cable
  from the Poplar's micro USB based serial port to your host
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

- There is a "USB_BOOT" button on the board.  It is one of two
  buttons on same side of the boards as the stacked USB 2.0 ports.
  To boot from the memory stick, this button needs to be depressed
  at power-on.  You only need to hold it for about a second;
  keeping it down a bit longer does no harm.

- Next you will be powering on the board, but you need to interrupt
  the automated boot process.  To do this, be prepared to press a
  key, perhaps repeatedly, in the serial console window until you
  find the boot process has stopped.

- Power on the Poplar board (while pressing the USB_BOOT button),
  and interrupt its automated boot with a key press.

- Now enter the following commands in the Poplar serial console

```shell
    usb reset
    fatload usb 0:1 ${scriptaddr} install.scr
    source ${scriptaddr}
```

  It will take about 5-10 minutes to complete writing out the contents
  of the disk.  The result should look a bit like this:

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

  You'll want to stop any automatic boot after this.  When prompted
  with:

```shell
    Hit any key to stop autoboot:
```
  press a key to interrupt it.  At the "poplar#" propmt, issue this
  command to boot Android:

```shell
    run bootai
```
  At this point, Android should boot in console mode.

You have now booted your Poplar board into Android starting only
from source code.
