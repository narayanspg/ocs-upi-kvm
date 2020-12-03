#!/bin/bash

# Create and attach a data disk to each worker node

# One can attach a disk partition or a qcow2 file.  The qcow2 method is
# the default, which can be overridden by specifying a comma separated list
# of disk partitions via the environment variable DATA_DISK_LIST.

# Assumes caller sets environment variable KUBECONFIG

set -e

user=$(whoami)
if [ "$user" != "root" ]; then
	echo "You must be root user to invoke this script $0"
	exit 1
fi

if [ ! -e helper/parameters.sh ]; then
	echo "Please invoke this script from the directory ocs-upi-kvm/scripts"
	exit 1
fi

source helper/parameters.sh

VDISK=${VDISK:="vdc"}

echo KUBECONFIG=$KUBECONFIG
echo WORKSPACE=$WORKSPACE

if [[ "$DATA_DISK_SIZE" -le "0" ]]; then
	echo "No data disks will be created"
	exit
fi

# If OCS is configured, give more time for each node to recover
# before modifying the next one

set +e
ocs_configured=$($WORKSPACE/bin/oc get projects | grep ^openshift-storage)
set -e
if [ -n "$ocs_configured" ]; then
	delay=60
else
	delay=10
fi

if [ -z "$DATA_DISK_ARRAY" ]; then
	# Remember where data files will be created for virsh_cleanup.sh
	echo "$IMAGES_PATH" > $WORKSPACE/.images_path
	# Remove old images in case virsh_cleanup.sh is not run
	rm -f $IMAGES_PATH/test-ocp$SANITIZED_OCP_VERSION/*.data
fi

for (( i=0; i<$WORKERS; i++ ))
do
	if [ -n "$DATA_DISK_ARRAY" ]; then
		disk_path=/dev/${DATA_DISK_ARRAY[$i]}
		if [ "$FORCE_DISK_PARTITION_WIPE" == "true" ]; then
			echo "Wiping $disk_path.  This takes ~30 minutes for a 500G disk..."
			wipe -I $disk_path
			echo "Completed disk wipe of $disk_path"
			DATA_DISK_SIZE=$(fdisk -l $disk_path | head -n 1 | awk '{print $3}')
			DATA_DISK_SIZE=${DATA_DISK_SIZE/\.*/}
		fi
	else
		disk_path=$IMAGES_PATH/test-ocp$SANITIZED_OCP_VERSION/disk-worker${i}.data-$VDISK
		if [ -e $disk_path ]; then
			echo "WARNING: Overwriting data disk file $disk_path"
		fi
	fi

	echo "Creating data disk $disk_path of size ${DATA_DISK_SIZE}G"
	qemu-img create -f raw $disk_path ${DATA_DISK_SIZE}G

	vm=$(virsh list --all | grep worker-$i | tail -n 1 | awk '{print $2}')
	echo "Attaching data disk to $vm at $VDISK"
	virsh attach-disk $vm --source $disk_path --target $VDISK --persistent
	virsh reboot $vm
	sleep $delay
done

# Wait for each node to become ready

echo "Waiting up to ${delay}0 seconds for each worker node to become ssh accessible"

for (( i=0; i<$WORKERS; i++ ))
do
	vm=$(virsh list --all | grep worker-$i | awk '{print $2}' | tail -n 1)

	success=false
	for ((cnt=0; cnt<3; cnt++))
	do
		ip=$($WORKSPACE/bin/oc get nodes -o wide | grep worker-$i | tail -n 1 | awk '{print $6}')
		if [ -n "$ip" ]; then
			cnt=3
			success=true
		else
			sleep 10
		fi
	done

	if [ "$success" == false ]; then
		echo "WARNING: IP Address for VM $vm is not known, continuing anyway"
		continue
	fi

	success=false
	for ((cnt=0; cnt<10; cnt++))
	do
		sleep $delay

		set +e
		ls_out=$(su - $SUDO_USER -c "ssh -o StrictHostKeyChecking=no core@$ip ls /")
		set -e

		if [ -n "$ls_out" ]; then
			cnt=10
			success=true
		fi
	done

	if [ "$success" == false ]; then
		echo "WARNING: VM $vm at $ip is not ssh accessible, continuing anyway"
	else
		echo "VM $vm at $ip is ssh accessible"
	fi
done
