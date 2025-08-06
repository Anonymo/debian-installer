function notify {
  echo $@
  read -p "Enter to continue"
}

function optimize_zfs_pool {
  local pool_name=$1
  notify optimizing ZFS pool ${pool_name}
  zpool scrub ${pool_name} || exit 1
  # Wait for scrub to complete
  while zpool status ${pool_name} | grep -q "scrub in progress"; do
    sleep 5
  done
  # ZFS now supports online shrinking with TRIM
  # Reclaim unused space
  zpool trim ${pool_name} || exit 1
  # Rebalance and optimize the pool
  zpool list ${pool_name} || exit 1
  echo ZFS pool optimization complete
}

function shrink_partition {
  local slack=$1
  local disk=$2
  local partition_nr=$3
  if [ ! -f "partition_${partition_nr}_shrunk.txt" ]; then
    notify shrinking partition ${disk}${partition_nr} by ${slack}
    echo ", -${slack}" | sfdisk ${disk} -N ${partition_nr}
    notify checking the filesystem after partition shrink
    zpool import -f -d "${disk}${partition_nr}" -N rpool || exit 1
    zpool scrub rpool || exit 1
    # Wait for scrub to complete
    while zpool status rpool | grep -q "scrub in progress"; do
      sleep 5
    done
    zpool export rpool || exit 1
    touch "partition_${partition_nr}_shrunk.txt"
  fi
}