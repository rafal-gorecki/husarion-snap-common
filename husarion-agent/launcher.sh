#!/bin/sh
# launcher.sh — daemon launcher for the husarion-agent embedded in
# a Husarion snap. Replaces each snap's per-repo copy under
# snap/local/husarion_agent_launcher.sh.
#
# Seeds the files-first config-root (agent.yaml / follow.yaml / config/ /
# hooks/ / manifests/) into the writable $SNAP_COMMON tree the agent reads
# and execs from (the snap-confined $SNAP is read-only, and snapd refuses
# to introspect read-only execs on some revisions), then exec's the agent.
#
# Env (set by the consumer snap's snapcraft.yaml `environment:` block):
#   HA_PEER_BIND  — `0.0.0.0:<port>` to start an in-snap mTLS
#                   listener (cascading-primary mode). Only the
#                   rosbot snap currently sets this (:7444). Leaf
#                   followers omit it.
#
# Built-in snap env (always set by snapd inside the daemon child):
#   SNAP_INSTANCE_NAME, SNAP_COMMON, SNAP
set -eu

STATE_DIR="${SNAP_COMMON}/husarion-agent"
SOCK="${STATE_DIR}/agent.sock"
PANELS_DEFAULT="${SNAP}/usr/share/husarion-agent/panels.d"
PANELS_OVERRIDES="${STATE_DIR}/panels.d"
# Same two-directory idiom as panels. Both dirs must live under the
# snap-confined $SNAP (read-only, package-shipped) / $SNAP_COMMON
# (writable, operator-editable) tree — NOT husarion-agent's own bare CLI
# defaults (/usr/share/husarion-agent/advisories.d, /etc/husarion-agent/
# advisories.d), which are host-absolute paths a strict-confinement
# AppArmor profile denies. Left unset once, that denial used to crash-loop
# the whole daemon on every boot (HW 2026-08-26, rosbot: agent never got
# past startup, so it never reached its peer follow-task and ROS_NAMESPACE
# never cascaded to the snap). husarion-agent now degrades a denied
# overrides dir gracefully too (belt and suspenders), but the daemon
# should never be pointed at an unreachable path in the first place.
ADVISORIES_DEFAULT="${SNAP}/usr/share/husarion-agent/advisories.d"
ADVISORIES_OVERRIDES="${STATE_DIR}/advisories.d"
mkdir -p "$STATE_DIR" "$PANELS_OVERRIDES" "$ADVISORIES_OVERRIDES" "${SNAP_COMMON}/peer-certs"

# Seed the files-first config-root from the snap-shipped seed.
#   identity + topology + initial config (agent.yaml / follow.yaml /
#   config/) are seeded ONLY IF ABSENT, so operator edits and config
#   pulled from an upstream survive a snap refresh.
#   hooks/ + manifests/ are re-copied on every (re)start so a refresh's
#   newer code wins (shipped > whatever was staged before).
SEED_ROOT="${SNAP}/usr/share/husarion-agent/config-seed"
if [ -d "$SEED_ROOT" ]; then
    # --no-preserve=ownership: cp -a's chown of the copy to the source's uid
    # needs CAP_CHOWN, which strict confinement's default daemon profile
    # doesn't grant even to a root-run service — copy as the running user
    # instead (mode/timestamps still preserved).
    for item in agent.yaml follow.yaml config; do
        if [ -e "$SEED_ROOT/$item" ] && [ ! -e "$STATE_DIR/$item" ]; then
            cp -a --no-preserve=ownership "$SEED_ROOT/$item" "$STATE_DIR/$item"
        fi
    done
    if [ -d "$SEED_ROOT/hooks" ]; then
        mkdir -p "$STATE_DIR/hooks"
        cp -a --no-preserve=ownership "$SEED_ROOT/hooks/." "$STATE_DIR/hooks/"
        find "$STATE_DIR/hooks" -type f -exec chmod 0755 {} +
    fi
    if [ -d "$SEED_ROOT/manifests" ]; then
        mkdir -p "$STATE_DIR/manifests"
        cp -a --no-preserve=ownership "$SEED_ROOT/manifests/." "$STATE_DIR/manifests/"
    fi
fi

export HUSARION_AGENT_HOSTNAME="${SNAP_INSTANCE_NAME:-$(basename "$0")}"

extra=""
[ -n "${HA_PEER_BIND:-}" ] && extra="$extra --peer-tls-bind ${HA_PEER_BIND}"

# --- content-interface chaining (SPEC-content-chain.md) ----------------------
# Same-host, zero-config chaining over the snap content interface. The role is
# selected by which directory exists — no per-snap launcher logic:
#   * PROVIDER (rosbot): its install hook mints $SNAP_COMMON/agent-chain (the
#     slot's write: source). Its presence → run the agent with
#     --content-join-dir so it advertises CA+URL there and signs CSRs followers
#     drop in requests/.
#   * FOLLOWER (rplidar/depthai): snapd creates the plug target
#     $SNAP_COMMON/agent-chain-upstream only while the interface is connected.
#     If it's there, best-effort self-heal the join in the BACKGROUND so the
#     daemon boots immediately; the fspeer follow loop adopts the cert as soon
#     as content-join writes it. `no-restart` because we're (re)starting anyway.
CONTENT_SLOT="${SNAP_COMMON}/agent-chain"
CONTENT_UPSTREAM="${SNAP_COMMON}/agent-chain-upstream"
content_extra=""
if [ -d "$CONTENT_SLOT" ]; then
    content_extra="--content-join-dir ${CONTENT_SLOT}"
elif [ -d "$CONTENT_UPSTREAM" ]; then
    FOLLOWER_HELPER="${SNAP}/usr/bin/content-join-follower.sh"
    if [ -x "$FOLLOWER_HELPER" ]; then
        "$FOLLOWER_HELPER" no-restart >/dev/null 2>&1 &
    fi
fi

# shellcheck disable=SC2086  # $extra / $content_extra are intentional word-split flag lists
exec "${SNAP}/usr/bin/husarion-agent" \
    --socket "$SOCK" \
    --state-dir "$STATE_DIR" \
    --config-root "$STATE_DIR" \
    --panels-default "$PANELS_DEFAULT" \
    --panels-overrides "$PANELS_OVERRIDES" \
    --advisories-default "$ADVISORIES_DEFAULT" \
    --advisories-overrides "$ADVISORIES_OVERRIDES" \
    $extra $content_extra
