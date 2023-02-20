#!/usr/bin/env bash

# Batch creation of NextcloudPi image
#
# Copyleft 2017 by Ignacio Nunez Hernanz <nacho _a_t_ ownyourbits _d_o_t_ com>
# GPL licensed (see end of file) * Use at your own risk!
#
# Usage: ./batch.sh <DHCP QEMU image IP>
#

function add_build_variables {
  declare -x -a BUILDVARIABLES; BUILDVARIABLES+=("$@")
  if [[ "${BUILDVARIABLES[*]}" != *"BUILDVARIABLES"* ]]
  then add_build_variables BUILDVARIABLES
  fi
}

if [[ -v DBG ]] && [[ -n "$DBG" ]]
then set -e"$DBG"
else set -e
fi

BUILDLIBRARY="${BUILDLIBRARY:-build/buildlib.sh}"; add_build_variables 'BUILDLIBRARY'

if [[ ! -f "$BUILDLIBRARY" ]]
then printf '\e[1;31mERROR\e[0m %s\n' "File not found: $BUILDLIBRARY"; exit 1
fi

# shellcheck disable=SC1090
source "$BUILDLIBRARY"

log -1 "Build NCP Raspberry Pi"

URL="https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2022-09-26/2022-09-22-raspios-bullseye-arm64-lite.img.xz"
SIZE=4G                     # Raspbian image size
#CLEAN=0                    # Pass this envvar to skip cleaning download cache
IMG="${IMG:-NextcloudPi_RPi_$( date  "+%m-%d-%y" ).img}"
TAR=output/"$( basename "$IMG" .img ).tar.bz2"

export ROOTDIR='raspbian_root'
export BUILD_DIR='tmp/ncp-build'
export BOOTDIR='raspbian_boot'
export DSHELL='/bin/bash'

add_build_variables URL SIZE IMG TAR ROOTDIR BOOTDIR BUILD_DIR DSHELL

##############################################################################

function clean_build_sd_rpi {
  clean_chroot_raspbian
  unset "${BUILDVARIABLES[@]}"
}

##############################################################################

if is_file "$TAR"
then log 1 "File exists: $TAR"; exit 0
fi

if find_full_process qemu-arm-static
then log 2 "qemu-arm-static already running"; exit 1
fi

if find_full_process qemu-aarch64-static
then log 2 "qemu-aarch64-static already running"; exit 1
fi

# # # # # # # # #
# Preparations  #
# # # # # # # # #

IMG=tmp/"$IMG"

trap 'clean_build_sd_rpi' EXIT SIGHUP SIGILL SIGABRT

# Directories: tmp cache output
prepare_dirs

# Raspberry Pi OS 64Bit-lite
download_raspbian "$URL" "$IMG"

# Change size of ISO image
resize_image      "$IMG" "$SIZE"

# PARTUUID has changed after resize
update_boot_uuid  "$IMG"

# Make sure we don't accidentally disable first run wizard
if is_root
then rm --force ncp-web/{wizard.cfg,ncp-web.cfg}
else sudo rm --force ncp-web/{wizard.cfg,ncp-web.cfg}
fi

## BUILD NCP

prepare_chroot_raspbian "$IMG"

if is_root
then mkdir "$ROOTDIR"/"$BUILD_DIR"
else sudo mkdir "$ROOTDIR"/"$BUILD_DIR"
fi

if is_root
then # shellcheck disable=SC2035
     rsync -Aax --exclude-from .gitignore --exclude *.img --exclude *.bz2 . "$ROOTDIR"/"$BUILD_DIR"
else # shellcheck disable=SC2035
     sudo rsync -Aax --exclude-from .gitignore --exclude *.img --exclude *.bz2 . "$ROOTDIR"/"$BUILD_DIR"
fi

if is_root
then PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
     chroot "$ROOTDIR" "$DSHELL" <<'EOFCHROOT'
set -ex

# allow oldstable
apt-get update --allow-releaseinfo-change --assume-yes 

# As of 10-2018 this upgrades raspi-kernel and messes up wifi and BTRFS
#apt-get upgrade -y
#apt-get dist-upgrade -y

# As of 03-2018, you dont get a big kernel update by doing
# this, so better be safe. Might uncomment again in the future
#$APTINSTALL rpi-update
#echo -e "y\n" | PRUNE_MODULES=1 rpi-update

# this image comes without resolv.conf ??
echo 'nameserver 1.1.1.1' >> /etc/resolv.conf

# install NCP
if ! cd /tmp/ncp-build
then printf '%s\n' "Failed to change directory to: /tmp/ncp-build"; exit 1
fi

systemctl daemon-reload
CODE_DIR="$PWD" bash install.sh

# work around dhcpcd Raspbian bug
# https://lb.raspberrypi.org/forums/viewtopic.php?t=230779
# https://github.com/nextcloud/nextcloudpi/issues/938
apt-get update  --allow-releaseinfo-change --assume-yes
apt-get install --assume-yes --no-install-recommends haveged
systemctl enable haveged.service

# harden SSH further for Raspbian
sed -i 's|^#PermitRootLogin .*|PermitRootLogin no|' /etc/ssh/sshd_config

# cleanup
if [[ -f 'etc/library.sh' ]]
then source etc/library.sh && run_app_unsafe post-inst.sh
fi

if [[ -f '/etc/resolv.conf' ]]
then rm /etc/resolv.conf
fi

if [[ -d '/tmp/ncp-build' ]]
then rm --recursive --force '/tmp/ncp-build'
fi

EOFCHROOT
else PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
     sudo chroot "$ROOTDIR" "$DSHELL" <<'EOFCHROOT'
set -ex

# allow oldstable
apt-get update --allow-releaseinfo-change --assume-yes

# As of 10-2018 this upgrades raspi-kernel and messes up wifi and BTRFS
#apt-get upgrade -y
#apt-get dist-upgrade -y

# As of 03-2018, you dont get a big kernel update by doing
# this, so better be safe. Might uncomment again in the future
#$APTINSTALL rpi-update
#echo -e "y\n" | PRUNE_MODULES=1 rpi-update

# this image comes without resolv.conf ??
printf '%s\n' 'nameserver 1.1.1.1' >> /etc/resolv.conf

# install NCP
if ! cd /tmp/ncp-build
then printf '%s\n' "Failed to change directory to: /tmp/ncp-build"; exit 1
fi

systemctl daemon-reload
CODE_DIR="$PWD" bash install.sh

# work around dhcpcd Raspbian bug
# https://lb.raspberrypi.org/forums/viewtopic.php?t=230779
# https://github.com/nextcloud/nextcloudpi/issues/938
apt-get update  --allow-releaseinfo-change --assume-yes
apt-get install --no-install-recommends --assume-yes haveged
systemctl enable haveged.service

# harden SSH further for Raspbian
sed -i 's|^#PermitRootLogin .*|PermitRootLogin no|' /etc/ssh/sshd_config

# cleanup
if [[ -f 'etc/library.sh' ]]
then source etc/library.sh && run_app_unsafe post-inst.sh
fi

if [[ -f '/etc/resolv.conf' ]]
then rm /etc/resolv.conf
fi

if [[ -d '/tmp/ncp-build' ]]
then rm --recursive --force '/tmp/ncp-build'
fi

EOFCHROOT
fi

if is_root
then log -1 "Image created: $(basename "$IMG")"
     basename "$IMG" | tee "$ROOTDIR"/usr/local/etc/ncp-baseimage
else log -1 "Image created: $(sudo basename "$IMG")"
     sudo basename "$IMG" | sudo tee "$ROOTDIR"/usr/local/etc/ncp-baseimage
fi

clean_build_sd_rpi

trap - EXIT SIGHUP SIGILL SIGABRT SIGINT

# pack_image "$IMG" "$TAR"

## Pack IMG
[[ "$*" =~ .*"--pack".* ]] && { log -1 "Packing image"; pack_image "$IMG" "$TAR"; }

log 0 "Build is complete"; exit 0

## test

#set_static_IP "$IMG" "$IP"
#test_image    "$IMG" "$IP" # TODO fix tests

# upload
#create_torrent "$TAR"
#upload_ftp "$( basename "$TAR" .tar.bz2 )"


# License
#
# This script is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this script; if not, write to the
# Free Software Foundation, Inc., 59 Temple Place, Suite 330,
# Boston, MA  02111-1307  USA
