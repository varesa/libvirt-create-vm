#!/bin/sh

set -euo pipefail

#
# Conf

# Filesystem path for the resulting virtual disk
volumes="/tank/vms"

# Name of the libvirt network (virsh net-list)
network="ovsbr"

# Initial root password. No '-characters please
root_password="password" 

#
# Prereqs
rpm -q rsync 2>&1 >/dev/null || dnf install -y rsync
rpm -q virt-install 2>&1 >/dev/null || dnf install -y virt-install
rpm -q libguestfs-tools-c 2>&1 >/dev/null || dnf install -y libguestfs-tools-c

#
# Parameters

if [ "$#" != "5" ] && [ "$#" != "7" ]; then
	echo "Usage: $0 <image path> <vm hostname> <network portgroup> <ip address with mask> <gateway address> [<cpu cores> <memory in MB>]"
	echo "For example: $0 /tank/iso/centos8.qcow2 test.tite.fi vlan-123-test 10.0.123.100/24 10.0.123.1"
	exit 1
fi

image="$1"
if ! test -f "$image"; then
	echo "Error: Image $image: file does not exist"
	exit 1
fi

name="$2"
volume_path="$volumes/$name.qcow2"
if test -f "$volume_path"; then
	echo "Error: Target disk $volume_path already exists"
	exit 1
fi

portgroup="$3"
if ! virsh net-dumpxml "$network" | grep -q "portgroup name=.${portgroup}."; then
	echo "Portgroup $portgroup not found in libvirt network $network"
	exit 1
fi

address="$4"
if ! echo "$address" | grep -qP '^\d+\.\d+\.\d+\.\d+/\d+$'; then
	echo "The address $address does not look like an ip/mask (like 10.0.0.1/24)"
	exit 1
fi

gateway="$5"
if ! echo "$gateway" | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
	echo "The gateway $gateway does not look like an IP addres (e.g. 10.0.0.1)"
	exit 1
fi

if [ "$#" != "7" ]; then
	cpu_cores="$6"
	if ! [[ "$cpu_cores" =~ "^[0-9]+$" ]]; then
		echo "The CPU core count $cpu_cores is not a number"
		exit 1
	fi
	memory_mb="$7"
	if ! [[ "$memory_mb" =~ "^[0-9]+$" ]]; then
		echo "The CPU core count $ram_mb is not a number"
		exit 1
	fi
else
	cpu_cores=2
	memory_mb=1024
fi

#
# Create disk
echo "Coyping image to $volume_path"
echo -n '- '; rsync --progress "$image" "$volume_path"
echo ""

#
# Mount image for modifications
mountpoint="$(mktemp -d)"
guestmount -i -a "$volume_path" "$mountpoint"

echo "Mounted $volume_path at $mountpoint"

echo "- creating network configuration"

address_ip="$(echo $address | cut -d '/' -f 1)"
prefix_length="$(echo $address | cut -d '/' -f 2)"

cat << EOF > $mountpoint/etc/sysconfig/network-scripts/ifcfg-eth0
DEVICE=eth0
NAME=eth0

BOOTPROTO=static
ONBOOT=yes

IPADDR=$address_ip
PREFIX=$prefix_length
GATEWAY=$gateway

DNS1=1.1.1.1
DNS2=8.8.8.8
EOF

echo "- setting hostname"
echo "$name" > "$mountpoint/etc/hostname"

echo "- disabling cloud-init"
for service in cloud-init cloud-init-local cloud-config cloud-final; do
    [ -L "$mountpoint/etc/systemd/system/$service.service" ] || ln -s /dev/null "$mountpoint/etc/systemd/system/$service.service"
done

echo "- setting root password"
hash="$(python3 -c "import crypt; print(crypt.crypt('$root_password', crypt.mksalt(crypt.METHOD_SHA512)))")"
days_since_epoch="$(($(date --utc +%s)/86400))"
sed -i "s;^root:.*;root:$hash:$days_since_epoch:0:99999:7:::;" "$mountpoint/etc/shadow"

echo "- forcing selinux to relabel on first boot"
touch "$mountpoint/.autorelabel"

echo "- unmounting"
umount "$mountpoint"
rmdir "$mountpoint"
echo ""

#
# Create VM
echo "Creating VM"
virt-install --memory 1024 --vcpus 1 \
    --name $name \
    --disk $volume_path,device=disk \
    --os-type Linux --os-variant rhel8.1 --virt-type kvm \
    --network "network=$network,model=virtio,virtualport_type=openvswitch,portgroup=$portgroup" \
    --vcpus $cpu_cores --memory $memory_mb \
    --graphics vnc \
    --import \
    --boot hd \
    --wait 0

