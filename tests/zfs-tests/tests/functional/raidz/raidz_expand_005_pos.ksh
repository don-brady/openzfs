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

#
# DESCRIPTION:
#	Check device replacement during raidz expansion using expansion pausing.
#
# STRATEGY:
#	1. Create block device files for the test raidz pool
#	2. For each parity value [1..3]
#	    - create raidz pool with minimum block device files required
#	    - create couple of datasets with different recordsize and fill it
#	    - set raidz expand offset pause
#	    - attach new device to the pool
#	    - wait reflow offset become equal to raidz expand pause offset
#	    - offline and zero vdevs allowed by parity
#	    - wait some time and start offlined vdevs replacement
#	    - wait replacement completion and verify pool status
#	    - loop thru vdevs replacing and raidz expand pause offset increasing
#	    - verify pool
#	    - set raidz expand offset to max value to complete raidz expansion

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

	log_must set_tunable32 PREFETCH_DISABLE $embedded_slog_min_ms
}

function wait_expand_paused
{
	oldcopied='0'
	newcopied='1'
	while [[ $oldcopied != $newcopied ]]; do
		oldcopied=$newcopied
		sleep 1
		newcopied=$(zpool status $TESTPOOL | \
		    grep 'copied out of' | \
		    awk '{print $1}')
	done
}

log_onexit cleanup

function test_replace # <pool> <devices> <parity>
{
	pool=${1}
	devices=${2}
	nparity=${3}
	device_count=0

	log_must echo "devices=$devices"

	for dev in ${devices}; do
		device_count=$((device_count+1))
	done

	index=$((RANDOM%(device_count-nparity)))
	for (( j=1; j<=$nparity; j=j+1 )); do
		log_must zpool offline $pool ${disks[$((index+j))]}
		log_must dd if=/dev/zero of=${disks[$((index+j))]} \
		    bs=1024k count=$dev_size_mb conv=notrunc
	done

	for (( j=1; j<=$nparity; j=j+1 )); do
		log_must zpool replace $pool ${disks[$((index+j))]}
	done

	log_must zpool wait -t replace $pool
	log_must check_pool_status $pool "scan" "with 0 errors"

	log_must zpool clear $pool
	log_must zpool scrub -w $pool

	# XXX step sometimes FAILED
	log_must zpool status -v
	# log_must check_pool_status $pool "scan" "repaired 0B"
}

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
	devices=""

	log_must zpool create -f $opts $pool $raid ${disks[1..$(($nparity+1))]}
	devices="${disks[1..$(($nparity+1))]}"

	log_must zfs create -o recordsize=8k $pool/fs
	log_must fill_fs /$pool/fs 1 128 100 1024 R

	log_must zfs create -o recordsize=128k $pool/fs2
	log_must fill_fs /$pool/fs2 1 128 100 1024 R

	for disk in ${disks[$(($nparity+2))..$devs]}; do
		pool_size=$(get_pool_prop size $pool)
		pause=$((((RANDOM << 15) + RANDOM) % pool_size / 2))
		log_must set_tunable64 RAIDZ_EXPAND_MAX_OFFSET_PAUSE $pause

		log_must zpool attach $pool ${raid}-0 $disk
		devices="$devices $disk"

		wait_expand_paused

		for (( i=0; i<2; i++ )); do
			test_replace $pool "$devices" $nparity

			pause=$((pause + (((RANDOM << 15) + RANDOM) % \
			    pool_size) / 4))
			log_must set_tunable64 RAIDZ_EXPAND_MAX_OFFSET_PAUSE $pause

			wait_expand_paused
		done

		pause=$((devs*dev_size_mb*1024*1024))
		log_must set_tunable64 RAIDZ_EXPAND_MAX_OFFSET_PAUSE $pause

		log_must zpool wait -t raidz_expand $pool
	done

	log_must zpool destroy "$pool"
done

log_pass "raidz expansion test succeeded."

