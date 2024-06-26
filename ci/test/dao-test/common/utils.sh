#!/bin/bash
# SPDX-License-Identifier: Marvell-MIT
# Copyright (c) 2024 Marvell.

set -euo pipefail

function find_executable()
{
	local execname=$1
	local execvar=$2
	local paths=${@:3}
	local bin

	for path in $paths; do
		if [[ $path != "" ]] && [[ -f $path/$execname ]]; then
			eval "$execvar"="$path/$execname"
			return
		fi
	done

	set +e
	bin=$(which $execname)
	set -e
	if [[ $bin != "" ]]; then
		eval "$execvar"="$bin"
		return
	fi
	echo "Cannot find $execname"
	exit 1
}

function ep_ssh_cmd()
{
	local remote_varname=$1
	local bg=$2
	local wait=$3
	local cmd=$4

	if [[ -z "${!remote_varname}" || -z "$EP_SSH_CMD" ]]; then
		echo "$remote_varname and SSH details are missing!!"
		exit 1
	fi

	if [[ $bg == "true" ]]; then
		$EP_SSH_CMD -f -n ${!remote_varname} "$cmd"
		sleep $wait
	else
		$EP_SSH_CMD ${!remote_varname} "$cmd"
	fi
}

function ep_host_ssh_cmd()
{
	local cmd=$1

	ep_ssh_cmd EP_HOST false 0 "$cmd"
}

function ep_host_op()
{
	local op=$1
	local args=${@:2}

	ep_host_ssh_cmd "sudo EP_HOST_DIR=$EP_HOST_DIR $EP_HOST_DIR/ci/test/dao-test/common/ep_host_utils.sh $op $args"
}

function ep_host_op_bg()
{
	local wait=$1
	local op=$2
	local args=${@:3}

	ep_ssh_cmd EP_HOST true $wait "sudo EP_HOST_DIR=$EP_HOST_DIR nohup $EP_HOST_DIR/ci/test/dao-test/common/ep_host_utils.sh $op $args 2>&1 &"
}

function ep_device_ssh_cmd()
{
	local cmd=$1

	ep_ssh_cmd EP_DEVICE false 0 "$cmd"
}

function ep_device_op()
{
	local op=$1
	local args=${@:2}

	ep_device_ssh_cmd "sudo EP_DEVICE_DIR=$EP_DEVICE_DIR $EP_DEVICE_DIR/ci/test/dao-test/common/ep_device_utils.sh $op $args"
}

function ep_device_op_bg()
{
	local wait=$1
	local op=$2
	local args=${@:3}

	ep_ssh_cmd EP_DEVICE true $wait "sudo EP_DEVICE_DIR=$EP_DEVICE_DIR nohup $EP_DEVICE_DIR/ci/test/dao-test/common/ep_device_utils.sh $op $args 2>&1 &"
}

function test_run()
{
	local func=$1
	local retry=${2:-1}
	local attempt=1
	local res

	while true; do
		echo "================================"
		echo "Run $func (Attempt $attempt)"
		echo "================================"
		set +e
		$func
		res=$?
		set -e

		# Break if test is successful
		if [[ $res == 0 ]]; then
			 break
		fi

		# Break if retry attempts exceeded
		attempt=$((attempt + 1))
		if [[ $attempt -gt $retry ]]; then
			break
		fi
	done

	return $res
}

function get_process_tree() {
	local pid=$BASHPID
	local ps_out
	local tree=""

	while [[ $pid != 1 ]]; do
		ps_out=$(ps -ef | grep $pid | awk '{printf("%d-%d ", $2, $3)}')
		tree+="$pid "
		for l in $ps_out; do
			if [[ $(echo $l | awk -F '-' '{print $1}') == $pid ]]; then
				pid=$(echo $l | awk -F '-' '{print $2}')
				break
			fi
		done
	done
	echo "$tree"
}

function safe_kill()
{
	local pattern=$@
	local killpids
	local ptree=$(get_process_tree)

	# Safely kill all processes which has the pattern in 'ps -ef' but
	# make sure that the current process tree is not affected.
	set +e
	killpids=$(ps -ef | grep "$pattern" | awk '{print $2}')
	for p in $killpids; do
		if ! $(echo $ptree | grep -qw $p); then
			kill -9 $p > /dev/null 2>&1
		fi
	done
	set -e
}

function file_offset()
{
	local logfile=$1

	# Get the offset of the file
	wc -c $logfile | awk '{print $1}'
}

function file_search_pattern()
{
	local logfile=$1
	local skip_bytes=$2
	local pattern=$3

	tail -c +$skip_bytes $logfile | grep -q "$pattern"
}
