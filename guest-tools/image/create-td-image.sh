#!/bin/bash
#
# Create a Ubuntu EFI cloud TDX guest image. It can run on any Linux system with
# required tool installed like qemu-img, virt-customize, virt-install, etc. It is
# not required to run on a TDX capable system.
#

WORK_DIR=${PWD}
CURR_DIR=$(dirname "$(realpath $0)")
USE_OFFICIAL_IMAGE=true
FORCE_RECREATE=false
OFFICIAL_UBUNTU_IMAGE=${OFFICIAL_UBUNTU_IMAGE:-"https://cloud-images.ubuntu.com/buildd/daily/noble/current/"}
CLOUD_IMG=${CLOUD_IMG:-"noble-server-cloudimg-amd64-disk1.img"}
GUEST_IMG="tdx-guest-ubuntu-24.04.qcow2"
SIZE=50
GUEST_USER=${GUEST_USER:-"tdx"}
GUEST_PASSWORD=${GUEST_PASSWORD:-"123456"}
GUEST_HOSTNAME=${GUEST_HOSTNAME:-"tdx-guest"}
GUEST_REPO=""

ok() {
    echo -e "\e[1;32mSUCCESS: $*\e[0;0m"
}

error() {
    echo -e "\e[1;31mERROR: $*\e[0;0m"
    cleanup
    exit 1
}

warn() {
    echo -e "\e[1;33mWARN: $*\e[0;0m"
}

check_tool() {
    [[ "$(command -v $1)" ]] || { error "$1 is not installed" 1>&2 ; }
}

usage() {
    cat <<EOM
Usage: $(basename "$0") [OPTION]...
  -h                        Show this help
  -c                        Create customize image (not from Ubuntu official cloud image)
  -f                        Force to recreate the output image
  -n                        Guest host name, default is "tdx-guest"
  -u                        Guest user name, default is "tdx"
  -p                        Guest password, default is "123456"
  -s                        Specify the size of guest image
  -o <output file>          Specify the output file, default is tdx-guest-ubuntu-24.04.qcow2.
                            Please make sure the suffix is qcow2. Due to permission consideration,
                            the output file will be put into /tmp/<output file>.
  -r <guest repo>           Specify the directory including guest packages, generated by build-repo.sh
EOM
}

process_args() {
    while getopts "o:s:n:u:p:r:fch" option; do
        case "$option" in
        o) GUEST_IMG=$OPTARG ;;
        s) SIZE=$OPTARG ;;
        n) GUEST_HOSTNAME=$OPTARG ;;
        u) GUEST_USER=$OPTARG ;;
        p) GUEST_PASSWORD=$OPTARG ;;
        r) GUEST_REPO=$OPTARG ;;
        f) FORCE_RECREATE=true ;;
        c) USE_OFFICIAL_IMAGE=false ;;
        h)
            usage
            exit 0
            ;;
        *)
            echo "Invalid option '-$OPTARG'"
            usage
            exit 1
            ;;
        esac
    done

    if [[ "${CLOUD_IMG}" == "${GUEST_IMG}" ]]; then
        error "Please specify a different name for guest image via -o"
    fi

    if [[ ${GUEST_IMG} != *.qcow2 ]]; then
        error "The output file should be qcow2 format with the suffix .qcow2."
    fi
}

download_image() {
    # Get the checksum file first
    if [[ -f ${CURR_DIR}/"SHA256SUMS" ]]; then
        rm ${CURR_DIR}/"SHA256SUMS"
    fi

    wget "${OFFICIAL_UBUNTU_IMAGE}/SHA256SUMS"

    while :; do
        # Download the cloud image if not exists
        if [[ ! -f ${CLOUD_IMG} ]]; then
            wget -O ${CURR_DIR}/${CLOUD_IMG} ${OFFICIAL_UBUNTU_IMAGE}/${CLOUD_IMG}
        fi

        # calculate the checksum
        download_sum=$(sha256sum ${CURR_DIR}/${CLOUD_IMG} | awk '{print $1}')
        found=false
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"$CLOUD_IMG"* ]]; then
                if [[ "${line%% *}" != ${download_sum} ]]; then
                    echo "Invalid download file according to sha256sum, re-download"
                    rm ${CURR_DIR}/${CLOUD_IMG}
                else
                    ok "Verify the checksum for Ubuntu cloud image."
                    return
                fi
                found=true
            fi
        done <"SHA256SUMS"
        if [[ $found != "true" ]]; then
            echo "Invalid SHA256SUM file"
            exit 1
        fi
    done
}

create_guest_image() {
    if [ ${USE_OFFICIAL_IMAGE} != "true" ]; then
        echo "Only support download the image from ${OFFICIAL_UBUNTU_IMAGE}"
        exit 1
    fi

    download_image

    cp ${CURR_DIR}/${CLOUD_IMG} /tmp/${GUEST_IMG}
    if [ $? -eq 0 ]; then
        ok "Copy the ${CLOUD_IMG} => /tmp/${GUEST_IMG}"
    else
        error "Failed to copy ${CLOUD_IMG} to /tmp"
    fi
}

config_guest_env() {
    virt-customize -a /tmp/${GUEST_IMG} \
        --copy-in /etc/environment:/etc
    if [ $? -eq 0 ]; then
        ok "Copy host's environment file to guest for http_proxy"
    else
        warn "Failed to Copy host's environment file to guest for http_proxy"
    fi
}

resize_guest_image() {
    qemu-img resize /tmp/${GUEST_IMG} +${SIZE}G
    virt-customize -a /tmp/${GUEST_IMG} \
        --run-command 'growpart /dev/sda 1' \
        --run-command 'resize2fs /dev/sda1' \
        --run-command 'systemctl mask pollinate.service'
    if [ $? -eq 0 ]; then
        ok "Resize the guest image to ${SIZE}G"
    else
        warn "Failed to resize guest image to ${SIZE}G"
    fi
}

config_cloud_init() {
    pushd ${CURR_DIR}/cloud-init-data
    [ -e /tmp/ciiso.iso ] && rm /tmp/ciiso.iso
    cp user-data.template user-data
    cp meta-data.template meta-data

    # configure the user-data
    cat <<EOT >> user-data

user: $GUEST_USER
password: $GUEST_PASSWORD
chpasswd: { expire: False }
EOT

    # configure the meta-dta
    cat <<EOT >> meta-data

local-hostname: $GUEST_HOSTNAME
EOT

    ok "Generate configuration for cloud-init..."
    genisoimage -output /tmp/ciiso.iso -volid cidata -joliet -rock user-data meta-data
    ok "Generate the cloud-init ISO image..."
    popd

    virt-install --memory 4096 --vcpus 4 --name tdx-config-cloud-init \
        --disk /tmp/${GUEST_IMG} \
        --disk /tmp/ciiso.iso,device=cdrom \
        --os-variant ubuntu24.04 \
        --virt-type kvm \
        --graphics none \
        --import \
        --wait=3
    if [ $? -eq 0 ]; then
        ok "Complete cloud-init..."
        sleep 1
    else
        error "Failed to configure cloud init"
    fi

    virsh destroy tdx-config-cloud-init || true
    virsh undefine tdx-config-cloud-init || true
}

setup_guest_image() {
    virt-customize -a /tmp/${GUEST_IMG} \
        --copy-in ${CURR_DIR}/setup.sh:/tmp/
    virt-customize -a /tmp/${GUEST_IMG} \
        --copy-in ${CURR_DIR}/../../setup-tdx-guest.sh:/tmp/
    virt-customize -a /tmp/${GUEST_IMG} \
        --run-command "/tmp/setup.sh"
    if [ $? -eq 0 ]; then
        ok "Setup guest image..."
    else
        error "Failed to setup guest image"
    fi
}

cleanup() {
    if [[ -f ${CURR_DIR}/"SHA256SUMS" ]]; then
        rm ${CURR_DIR}/"SHA256SUMS"
    fi
    ok "Cleanup!"
}

# install required tools
echo "Installing required tools ..."
apt install --yes qemu-utils libguestfs-tools virtinst genisoimage

check_tool qemu-img
check_tool virt-customize
check_tool virt-install
check_tool genisoimage

process_args "$@"

#
# Check user permission
#
if (( $EUID != 0 )); then
    warn "Current user is not root, please use root permission via \"sudo\" or make sure current user has correct "\
         "permission by configuring /etc/libvirt/qemu.conf"
    warn "Please refer https://libvirt.org/drvqemu.html#posix-users-groups"
    sleep 5
fi

create_guest_image
resize_guest_image

config_guest_env
config_cloud_init

setup_guest_image

cleanup

mv /tmp/${GUEST_IMG} ${WORK_DIR}/
chmod a+rw ${WORK_DIR}/${GUEST_IMG}

ok "TDX guest image : ${WORK_DIR}/${GUEST_IMG}"
