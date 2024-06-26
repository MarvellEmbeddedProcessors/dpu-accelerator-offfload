#!/bin/bash
# SPDX-License-Identifier: Marvell-MIT
# Copyright (c) 2024 Marvell.

set -euo pipefail

VIRTIO_UTILS_SCRIPT_PATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
source $VIRTIO_UTILS_SCRIPT_PATH/../common/utils.sh
source $VIRTIO_UTILS_SCRIPT_PATH/../common/ep_host_utils.sh
source $VIRTIO_UTILS_SCRIPT_PATH/../common/ep_device_utils.sh
source $VIRTIO_UTILS_SCRIPT_PATH/../common/testpmd.sh

find_executable "dao-virtio-l2fwd" VIRTIO_L2FWD "$VIRTIO_UTILS_SCRIPT_PATH/../../../../app"

function l2fwd_device_start_traffic()
{
	local pfx=$1
	local if0=$2

	echo "Starting traffic on device"
	testpmd_launch "$pfx" "-l 1-3 -a $if0 " \
	       "--no-flush-rx --forward-mode=io --rxq 1 --txq 1"
	testpmd_cmd "$pfx" "start tx_first"
	echo "Started traffic on device"
}

function l2fwd_device_stop_traffic()
{
	local pfx=$1

	echo "Stopping traffic on device"
	testpmd_cmd "$pfx" "stop"
	testpmd_quit "$pfx"
	testpmd_cleanup "$pfx"
	echo "Stopped traffic on device"
}

function l2fwd_device_check_pps()
{
	local pfx=$1
	local wait_time_sec=10

	while [[ wait_time_sec -ne 0 ]]
	do
		rx_pps=$(testpmd_pps $pfx 0)

		if [[ rx_pps -eq 0 ]]; then
			echo "Low PPS for ${pfx} ($rx_pps == 0)"
		else
			echo "Rx PPS $rx_pps as expected"
			return 0
		fi

		sleep 1
		wait_time_sec=$((wait_time_sec - 1))
	done

	return 1
}

function l2fwd_host_start_traffic()
{
	local pfx=$1
	local num_cores
	local fwd_cores
	local eal_args
	local app_args

	num_cores=$(ep_host_ssh_cmd "nproc --all")
	fwd_cores=$((num_cores - 1))
	eal_args="-l 0-$fwd_cores --socket-mem 1024 --proc-type auto --file-prefix=$pfx --no-pci \
		  --vdev=net_virtio_user0,path=/dev/vhost-vdpa-0,mrg_rxbuf=01,packed_vq=1,in_order=1,queue_size=4096"
	app_args="--nb-cores=$fwd_cores --port-topology=loop --rxq=$fwd_cores --txq=$fwd_cores -i"

	echo "Starting Traffic on Host"
	ep_host_op_bg 10 testpmd_launch $pfx "$eal_args" -- "$app_args"
	ep_host_op testpmd_cmd $pfx start
	echo "Started Traffic no Host"
}

function l2fwd_host_stop_traffic()
{
	local pfx=$1

	echo "Stopping Traffic on Host"
	ep_host_op testpmd_cmd $pfx stop
	ep_host_op testpmd_stop $pfx
	echo "Stopped Traffic no Host"
}

function l2fwd_sig_handler()
{
	local status=$?
	local sig=$1
	local pfx=$2
	set +e
	trap - ERR
	trap - INT
	trap - QUIT
	trap - EXIT
	if [[ $status -ne 0 ]]; then
		echo "$sig Handler"
	fi

	safe_kill $pfx
	ep_host_op safe_kill $pfx
}

function l2fwd_register_sig_handler()
{
	local pfx=$1

	# Register the traps
	trap "l2fwd_sig_handler ERR $pfx" ERR
	trap "l2fwd_sig_handler INT $pfx" INT
	trap "l2fwd_sig_handler QUIT $pfx" QUIT
	trap "l2fwd_sig_handler EXIT $pfx" EXIT
}

function l2fwd_app_launch()
{
	local interface=$1
	local l2fwd_pfx=$2
	local l2fwd_out=$3
	local cores="$4"
	local app_args="$5"
	local eal_args="
		-a 0000:06:00.1 -a 0000:06:00.2 -a 0000:06:00.3 -a 0000:06:00.4
		-a 0000:06:00.5 -a 0000:06:00.6 -a 0000:06:00.7 -a 0000:06:01.0
		-a 0000:06:01.1 -a 0000:06:01.2 -a 0000:06:01.3 -a 0000:06:01.4
		-a 0000:06:01.5 -a 0000:06:01.6 -a 0000:06:01.7 -a 0000:06:02.0
		-a 0000:06:02.1 -a 0000:06:02.2 -a 0000:06:02.3 -a 0000:06:02.4
		-a 0000:06:02.5 -a 0000:06:02.6
	"
	local args="-l $cores -a $interface $eal_args -- $app_args"
	local unbuffer

	unbuffer="$(command -v stdbuf) -o 0" || unbuffer=
	rm -rf $l2fwd_out
	echo "VIRTIO_L2FWD: $l2fwd_pfx: Launching dao-virtio-l2fwd"
	echo "Args: '$args'"

	$unbuffer $VIRTIO_L2FWD --file-prefix $l2fwd_pfx $args &>$l2fwd_out 2>&1 &

	# Wait for virtio_l2fwd to be up
	local itr=0
	while ! (tail -n20 $l2fwd_out | grep -q "VIRTIO_L2FWD: Entering graph main loop"); do
		sleep 1
		itr=$((itr + 1))
		if [[ itr -eq 10 ]]; then
			echo "Timeout waiting for virtio-l2fwd";
			cat $l2fwd_out
			return 1;
		fi
		echo "Waiting for virtio-l2fwd to be up"
	done
}
