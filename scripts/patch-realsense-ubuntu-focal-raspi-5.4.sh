#!/bin/bash

#Break execution on any error received
set -e
set -x
#Locally suppress stderr to avoid raising not relevant messages
exec 3>&2
exec 2> /dev/null
con_dev=$(ls /dev/video* | wc -l)
exec 2>&3

if [ $con_dev -ne 0 ];
then
	echo -e "\e[32m"
	read -p "Remove all RealSense cameras attached. Hit any key when ready"
	echo -e "\e[0m"
fi

#Include usability functions
source ./scripts/patch-utils.sh

# Get the required tools and headers to build the kernel
#sudo apt-get install linux-headers-generic build-essential git bc -y
#Packages to build the patched modules
require_package libusb-1.0-0-dev
require_package libssl-dev

#Parse user inputs
#Reload stock drivers (Developers' option)
[ "$#" -ne 0 -a "$1" == "reset" ] && reset_driver=1 || reset_driver=0
#Rebuild USB subsystem w/o kernel rebuild
[ "$#" -ne 0 -a "$1" == "build_usbcore_modules" ] && build_usbcore_modules=1 || build_usbcore_modules=0

retpoline_retrofit=0

LINUX_BRANCH=$(uname -r)
#Get kernel major.minor
IFS='.' read -a kernel_version <<< ${LINUX_BRANCH}
k_maj_min=$((${kernel_version[0]}*100 + ${kernel_version[1]}))

# Construct branch name from distribution codename {xenial,bionic,..} and kernel version
ubuntu_codename=`. /etc/os-release; echo ${UBUNTU_CODENAME/*, /}`

kernel_branch=raspi-5.4
kernel_source="${ubuntu_codename}-$kernel_branch"
echo -e "\e[32mCreate patches workspace in \e[93m${kernel_source} \e[32mfolder\n\e[0m"

#Distribution-specific packages
require_package libelf-dev
require_package elfutils
#Ubuntu 18.04 kernel 4.18
require_package bison
require_package flex


# Get the linux kernel and change into source tree
if [ ! -d ${kernel_source} ]; then
	mkdir ${kernel_source}
fi

cd ${kernel_source}
sudo apt-get source linux-image-$(uname -r)
cd linux-raspi-5.4.0

if [ $reset_driver -eq 1 ];
then 
	echo -e "\e[43mUser requested to rebuild and reinstall ubuntu-${ubuntu_codename} stock drivers\e[0m"
else
	# Patching kernel for RealSense devices
	echo -e "\e[32mApplying patches for \e[36m${ubuntu_codename}-${kernel_branch}\e[32m line\e[0m"
	echo -e "\e[32mApplying realsense-uvc patch\e[0m"
	patch -p1 < ../scripts/realsense-camera-formats-${ubuntu_codename}-${kernel_branch}.patch
	echo -e "\e[32mApplying realsense-metadata patch\e[0m"
	patch -p1 < ../scripts/realsense-metadata-${ubuntu_codename}-${kernel_branch}.patch
	echo -e "\e[32mApplying realsense-hid patch\e[0m"
	patch -p1 < ../scripts/realsense-hid-${ubuntu_codename}-${kernel_branch}.patch
	echo -e "\e[32mApplying realsense-powerlinefrequency-fix-${ubuntu_codename}-${kernel_branch} patch\e[0m"
	patch -p1 < ../scripts/realsense-powerlinefrequency-control-fix-${ubuntu_codename}-${kernel_branch}.patch
fi

#Copy configuration
sudo cp /usr/src/linux-headers-$(uname -r)/.config .
sudo cp /usr/src/linux-headers-$(uname -r)/Module.symvers .

#Reuse current kernel configuration. Assign default values to newly-introduced options.
sudo make olddefconfig modules_prepare
#Replacement of  USBcore modules implies usbcore is modular
[ ${build_usbcore_modules} -eq 1 ] && sudo make menuconfig modules_prepare

#Vermagic identity is required
sudo sed -i "s/\".*\"/\"$LINUX_BRANCH\"/g" ./include/generated/utsrelease.h
sudo sed -i "s/.*/$LINUX_BRANCH/g" ./include/config/kernel.release

# Build the uvc, accel and gyro modules
KBASE=`pwd`
cd drivers/media/usb/uvc
sudo cp $KBASE/Module.symvers .

echo -e "\e[32mCompiling uvc module\e[0m"
sudo make -j -C $KBASE M=$KBASE/drivers/media/usb/uvc/ modules
echo -e "\e[32mCompiling accelerometer and gyro modules\e[0m"
sudo make -j -C $KBASE M=$KBASE/drivers/iio/accel modules
sudo make -j -C $KBASE M=$KBASE/drivers/iio/gyro modules
echo -e "\e[32mCompiling v4l2-core modules\e[0m"
sudo make -j -C $KBASE M=$KBASE/drivers/media/v4l2-core modules

# Copy the patched modules to a  location
sudo cp $KBASE/drivers/media/usb/uvc/uvcvideo.ko ~/$LINUX_BRANCH-uvcvideo.ko
sudo cp $KBASE/drivers/iio/accel/hid-sensor-accel-3d.ko ~/$LINUX_BRANCH-hid-sensor-accel-3d.ko
sudo cp $KBASE/drivers/iio/gyro/hid-sensor-gyro-3d.ko ~/$LINUX_BRANCH-hid-sensor-gyro-3d.ko
sudo cp $KBASE/drivers/media/v4l2-core/videodev.ko ~/$LINUX_BRANCH-videodev.ko


if [ $build_usbcore_modules -eq 1 ]; then
	sudo make -j -C $KBASE M=$KBASE/drivers/usb/core modules
	sudo make -j -C $KBASE M=$KBASE/drivers/usb/host modules
	sudo make -j -C $KBASE M=$KBASE/drivers/hid/usbhid modules
	sudo cp $KBASE/drivers/media/v4l2-core/videobuf2-v4l2.ko ~/$LINUX_BRANCH-videobuf2-v4l2.ko
	sudo cp $KBASE/drivers/media/v4l2-core/videobuf2-core.ko ~/$LINUX_BRANCH-videobuf2-core.ko
	sudo cp $KBASE/drivers/media/v4l2-core/v4l2-common.ko ~/$LINUX_BRANCH-v4l2-common.ko
	sudo cp $KBASE/drivers/usb/core/usbcore.ko ~/$LINUX_BRANCH-usbcore.ko
	sudo cp $KBASE/drivers/usb/host/ehci-hcd.ko ~/$LINUX_BRANCH-ehci-hcd.ko
	sudo cp $KBASE/drivers/usb/host/ehci-pci.ko ~/$LINUX_BRANCH-ehci-pci.ko
	sudo cp $KBASE/drivers/usb/host/xhci-hcd.ko ~/$LINUX_BRANCH-xhci-hcd.ko
	sudo cp $KBASE/drivers/usb/host/xhci-pci.ko ~/$LINUX_BRANCH-xhci-pci.ko
	sudo cp $KBASE/drivers/hid/usbhid/usbhid.ko ~/$LINUX_BRANCH-usbhid.ko
fi

echo -e "\e[32mPatched kernels modules were created successfully\n\e[0m"

# Load the newly-built modules
# As a precausion start with unloading the core uvcvideo:
try_unload_module uvcvideo
try_unload_module videodev

echo $build_usbcore_modules
if [ $build_usbcore_modules -eq 1 ]; then
try_unload_module videobuf2_v4l2
try_unload_module videobuf2_core
try_unload_module v4l2_common


	#Replace usb subsystem modules
	try_unload_module usbhid
	try_unload_module xhci-pci
	try_unload_module xhci-hcd
	try_unload_module ehci-pci
	try_unload_module ehci-hcd

	try_module_insert usbcore				~/$LINUX_BRANCH-usbcore.ko 				/lib/modules/`uname -r`/kernel/drivers/usb/core/usbcore.ko
	try_module_insert ehci-hcd				~/$LINUX_BRANCH-ehci-hcd.ko 			/lib/modules/`uname -r`/kernel/drivers/usb/host/ehci-hcd.ko
	try_module_insert ehci-pci				~/$LINUX_BRANCH-ehci-pci.ko 			/lib/modules/`uname -r`/kernel/drivers/usb/host/ehci-pci.ko
	try_module_insert xhci-hcd				~/$LINUX_BRANCH-xhci-hcd.ko 			/lib/modules/`uname -r`/kernel/drivers/usb/host/xhci-hcd.ko
	try_module_insert xhci-pci				~/$LINUX_BRANCH-xhci-pci.ko 			/lib/modules/`uname -r`/kernel/drivers/usb/host/xhci-pci.ko

	try_module_insert videodev				~/$LINUX_BRANCH-videodev.ko 			/lib/modules/`uname -r`/kernel/drivers/media/v4l2-core/videodev.ko
	try_module_insert v4l2-common			~/$LINUX_BRANCH-v4l2-common.ko			/lib/modules/`uname -r`/kernel/drivers/media/v4l2-core/v4l2-common.ko

	try_module_insert videobuf2_core		~/$LINUX_BRANCH-videobuf2-core.ko		/lib/modules/`uname -r`/kernel/drivers/media/v4l2-core/videobuf2-core.ko
	try_module_insert videobuf2_v4l2		~/$LINUX_BRANCH-videobuf2-v4l2.ko		/lib/modules/`uname -r`/kernel/drivers/media/v4l2-core/videobuf2-v4l2.ko
fi

try_module_insert videodev				~/$LINUX_BRANCH-videodev.ko 			/lib/modules/`uname -r`/kernel/drivers/media/v4l2-core/videodev.ko
try_module_insert uvcvideo				~/$LINUX_BRANCH-uvcvideo.ko 			/lib/modules/`uname -r`/kernel/drivers/media/usb/uvc/uvcvideo.ko
try_module_insert hid_sensor_accel_3d 	~/$LINUX_BRANCH-hid-sensor-accel-3d.ko 	/lib/modules/`uname -r`/kernel/drivers/iio/accel/hid-sensor-accel-3d.ko
try_module_insert hid_sensor_gyro_3d	~/$LINUX_BRANCH-hid-sensor-gyro-3d.ko 	/lib/modules/`uname -r`/kernel/drivers/iio/gyro/hid-sensor-gyro-3d.ko


echo -e "\e[92m\n\e[1mScript has completed. Please consult the installation guide for further instruction.\n\e[0m"
