#!/bin/bash -e
#
# Initial ROS-side setup on snap install. Runs from the snap's
# `install` hook (e.g. rosbot-snap's snap/hooks/install).
#
# Seeds default `ros.*` config keys + populates the
# ${SNAP_COMMON}/rmw/ tree from the factory snapshot baked into
# $SNAP/usr/share/husarion-snap-common/config/rmw/. Also leaves
# back-compat symlinks at the legacy flat paths
# `${SNAP_COMMON}/dds-config-*.xml` so external callers that read
# the old paths directly keep working through the refactor.

# Define a function to log messages
source $SNAP/usr/bin/utils.sh

source_ros

if [[ $ROS_DISTRO == "humble" ]]; then
  snapctl set ros.localhost-only=''
elif [[ $ROS_DISTRO == "jazzy" ]]; then
  snapctl set ros.automatic-discovery-range="" # unset
  snapctl set ros.static-peers='' # unset
fi

snapctl set ros.transport="udp"
snapctl set ros.domain-id=0
snapctl set ros.namespace="" # unset

# Force factory defaults on first install (configure hook re-seeds only
# missing files on refresh, so operator edits survive). seed_rmw_tree also
# drops the back-compat dds-config-*.xml symlinks at the legacy flat paths,
# read by external callers (husarion-cockpit network capability, host-bash
# ros2 sourcing the old ros.env) — the snap's own hooks don't read them.
seed_rmw_tree --force
