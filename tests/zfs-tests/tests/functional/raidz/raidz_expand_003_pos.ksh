#!/bin/ksh -p
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2021 by vStack. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/cli_root/zfs_wait/zfs_wait.kshlib

#
# DESCRIPTION:
#	Check raidz expansion is able to work correctly under i/o load.
#
# STRATEGY:
#	1. Create block device files for the test raidz pool
#	2. For each parity value [1..3]
#	    - create raidz pool with minimum block device files required
#	    - create couple of datasets with different recordsize and fill it
#	    - set raidz expand maximum reflow bytes
#	    - start randwritecomp on one of the datasets files
#	    - attach new device to the pool
#	    - wait for reflow bytes to reach the maximum
#	    - kill randwritecomp
#	    - verify pool
#	    - set reflow bytes to max value to complete the expansion

typeset -r devs=10
typeset -r dev_size_mb=128

typeset -a disks

embedded_slog_min_ms=$(get_tunable EMBEDDED_SLOG_MIN_MS)

function cleanup
{
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	for i in {0..$devs}; do
		log_must rm -f "$TEST_BASE_DIR/dev-$i"
	done

	log_must set_tunable32 EMBEDDED_SLOG_MIN_MS $embedded_slog_min_ms
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
}

function wait_expand_paused
{
	oldcopied='0'
	newcopied='1'
	# wait until reflow copied value stops changing
	while [[ $oldcopied != $newcopied ]]; do
		oldcopied=$newcopied
		sleep 1
		newcopied=$(zpool status $TESTPOOL | \
		    grep 'copied out of' | \
		    awk '{print $1}')
	done
}

log_onexit cleanup

log_must set_tunable32 EMBEDDED_SLOG_MIN_MS 99999

# Disk files which will be used by pool
for i in {0..$(($devs))}; do
	device=$TEST_BASE_DIR/dev-$i
	log_must truncate -s ${dev_size_mb}M $device
	disks[${#disks[*]}+1]=$device
done

for nparity in 1 2 3; do
	raid=raidz$nparity
	pool=$TESTPOOL
	opts="-o cachefile=none"

	log_must zpool create -f $opts $pool $raid ${disks[1..$(($nparity+1))]}

	log_must zfs create -o recordsize=8k $pool/fs
	log_must fill_fs /$pool/fs 1 128 100 1024 R

	log_must zfs create -o recordsize=128k $pool/fs2
	log_must fill_fs /$pool/fs2 1 128 100 1024 R

	for disk in ${disks[$(($nparity+2))..$devs]}; do
		pool_size=$(get_pool_prop size $pool)
		# Pause at random location near the end of vdev
		pause=$((((RANDOM << 15) + RANDOM) % pool_size))
		log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES $pause

		log_bkgrnd randwritecomp /$pool/fs/file
		pid0=$!

		log_bkgrnd randwritecomp /$pool/fs2/file
		pid1=$!

		log_must zpool attach $pool ${raid}-0 $disk
		wait_expand_paused

		kill_if_running $pid0
		kill_if_running $pid1

		log_must zpool scrub -w $pool

		log_must check_pool_status $pool "errors" "No known data errors"
		log_must check_pool_status $pool "scan" "with 0 errors"
		log_must check_pool_status $pool "scan" "repaired 0B"

		# Set pause past largest possible value for this pool
		pause=$((devs*dev_size_mb*1024*1024))
		log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES $pause

		log_must zpool wait -t raidz_expand $pool
	done

	log_must zpool destroy "$pool"
done

log_pass "raidz expansion test succeeded."

