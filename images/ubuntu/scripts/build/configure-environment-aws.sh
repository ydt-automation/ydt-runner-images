#!/bin/bash -e
################################################################################
##  File:  configure-environment-aws.sh
##  Desc:  Configure system and environment for AWS instances
##         AWS-specific version of configure-environment.sh
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/os.sh
source $HELPER_SCRIPTS/etc-environment.sh

# Set ImageVersion and ImageOS env variables
set_etc_environment_variable "ImageVersion" "${IMAGE_VERSION}"
set_etc_environment_variable "ImageOS" "${IMAGE_OS}"

# Set the ACCEPT_EULA variable to Y value to confirm your acceptance of the End-User Licensing Agreement
set_etc_environment_variable "ACCEPT_EULA" "Y"

# This directory is supposed to be created in $HOME and owned by user(https://github.com/actions/runner-images/issues/491)
mkdir -p /etc/skel/.config/configstore
set_etc_environment_variable "XDG_CONFIG_HOME" '$HOME/.config'

# AWS-specific swap configuration
echo "Configuring swap for AWS EC2 instance"

# Check if we have ephemeral storage mounted at /mnt
if mountpoint -q /mnt; then
    echo "Ephemeral storage detected at /mnt, configuring swap file"
    # Create 4GB swap file on ephemeral storage
    sudo fallocate -l 4G /mnt/swapfile || sudo dd if=/dev/zero of=/mnt/swapfile bs=1M count=4096
    sudo chmod 600 /mnt/swapfile
    sudo mkswap /mnt/swapfile
    # Add to fstab for persistent mounting (but don't enable immediately)
    echo '/mnt/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    echo "Swap file created at /mnt/swapfile"
else
    echo "No ephemeral storage found at /mnt"
    # Check for NVMe instance store devices (newer instance types)
    nvme_devices=$(lsblk | grep nvme | grep -v nvme0n1 | awk '{print "/dev/"$1}' | head -1)
    if [ -n "$nvme_devices" ]; then
        echo "Found NVMe instance store device: $nvme_devices"
        # Format and mount the instance store device
        sudo mkfs.ext4 -F "$nvme_devices"
        sudo mount "$nvme_devices" /mnt
        # Create swap file on instance store
        sudo fallocate -l 4G /mnt/swapfile || sudo dd if=/dev/zero of=/mnt/swapfile bs=1M count=4096
        sudo chmod 600 /mnt/swapfile
        sudo mkswap /mnt/swapfile
        echo "Instance store mounted at /mnt and swap file created"
    else
        echo "No instance store found, swap will be handled by system if needed"
    fi
fi

# Add localhost alias to ::1 IPv6
sed -i 's/::1 ip6-localhost ip6-loopback/::1     localhost ip6-localhost ip6-loopback/g' /etc/hosts

# Prepare directory and env variable for toolcache
AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
mkdir $AGENT_TOOLSDIRECTORY
set_etc_environment_variable "AGENT_TOOLSDIRECTORY" "${AGENT_TOOLSDIRECTORY}"
set_etc_environment_variable "RUNNER_TOOL_CACHE" "${AGENT_TOOLSDIRECTORY}"
chmod -R 777 $AGENT_TOOLSDIRECTORY

# System optimization settings
# https://www.elastic.co/guide/en/elasticsearch/reference/current/vm-max-map-count.html
echo 'vm.max_map_count=262144' | tee -a /etc/sysctl.conf

# https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files
echo 'fs.inotify.max_user_watches=655360' | tee -a /etc/sysctl.conf
echo 'fs.inotify.max_user_instances=1280' | tee -a /etc/sysctl.conf

# https://github.com/actions/runner-images/issues/9491
echo 'vm.mmap_rnd_bits=28' | tee -a /etc/sysctl.conf

# Network optimization for cloud environments
echo 'net.core.rmem_default = 262144' | tee -a /etc/sysctl.conf
echo 'net.core.rmem_max = 16777216' | tee -a /etc/sysctl.conf
echo 'net.core.wmem_default = 262144' | tee -a /etc/sysctl.conf
echo 'net.core.wmem_max = 16777216' | tee -a /etc/sysctl.conf

# https://github.com/actions/runner-images/pull/7860
netfilter_rule='/etc/udev/rules.d/50-netfilter.rules'
rules_directory="$(dirname "${netfilter_rule}")"
mkdir -p $rules_directory
touch $netfilter_rule
echo 'ACTION=="add", SUBSYSTEM=="module", KERNEL=="nf_conntrack", RUN+="/usr/sbin/sysctl net.netfilter.nf_conntrack_tcp_be_liberal=1"' | tee -a $netfilter_rule

# Create symlink for tests running
chmod +x $HELPER_SCRIPTS/invoke-tests.sh
ln -s $HELPER_SCRIPTS/invoke-tests.sh /usr/local/bin/invoke_tests

# Disable motd updates metadata
sed -i 's/ENABLED=1/ENABLED=0/g' /etc/default/motd-news

# Remove fwupd if installed - not needed for cloud VMs
if systemctl list-unit-files fwupd-refresh.timer &>/dev/null; then
    echo "Masking fwupd-refresh.timer..."
    systemctl mask fwupd-refresh.timer
fi

# Legacy check for fwupd config
if [[ -f "/etc/fwupd/daemon.conf" ]]; then
    sed -i 's/UpdateMotd=true/UpdateMotd=false/g' /etc/fwupd/daemon.conf
fi

# AWS-specific optimizations
# Disable IPv6 if not needed (common in AWS environments)
if [ "${DISABLE_IPV6:-false}" = "true" ]; then
    echo 'net.ipv6.conf.all.disable_ipv6 = 1' | tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.default.disable_ipv6 = 1' | tee -a /etc/sysctl.conf
fi

# Configure CloudWatch agent compatibility
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
mkdir -p /var/log/amazon-cloudwatch-agent

# Set up environment for AWS CLI and tools
set_etc_environment_variable "AWS_DEFAULT_REGION" "us-east-1"
set_etc_environment_variable "AWS_PAGER" ""

# Disable Ubuntu Pro advertisements in MOTD
if [ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]; then
    mv /etc/apt/apt.conf.d/20apt-esm-hook.conf /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled
fi

# Configure systemd-resolved for better DNS performance in AWS
if [ -f /etc/systemd/resolved.conf ]; then
    sed -i 's/#DNS=/DNS=169.254.169.253/' /etc/systemd/resolved.conf
    sed -i 's/#FallbackDNS=/FallbackDNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
fi

# OpenSSL configuration - disable providers loading for Ubuntu 22
if is_ubuntu22; then
    sed -i 's/openssl_conf = openssl_init/#openssl_conf = openssl_init/g' /etc/ssl/openssl.cnf
fi

echo "AWS environment configuration completed"
