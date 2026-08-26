# husarion-snap-common

Shared library / staging tree for Husarion ROS 2 snaps. Pulled in by `rosbot-snap` (and any other Husarion snap) as a snapcraft `dump` part. Everything under `local-ros/` ends up at `$SNAP/usr/{bin,share/husarion-snap-common/config}/` in the consuming snap.

## What lives here

| Path | What |
|---|---|
| `local-ros/configure_hook_ros.sh` | Runs from the consuming snap's `configure` hook on every `snap set` / `snap unset` / refresh. Re-seeds any missing `${SNAP_COMMON}/rmw/` files (`seed_rmw_tree`, self-heal for robots upgraded across the 0.5.0→0.6.0 layout change — the install hook doesn't run on refresh), validates `ros.*` keys, resolves `ros.transport` → `RMW_IMPLEMENTATION` + profile path, writes `${SNAP_COMMON}/ros.env`. |
| `local-ros/install_hook_ros.sh` | Runs from the consuming snap's `install` hook on first install. Sets default `ros.*` values, force-seeds the `${SNAP_COMMON}/rmw/` tree from the factory snapshot (`seed_rmw_tree --force`), drops back-compat `dds-config-*.xml` symlinks. |
| `local-ros/utils.sh` | Shell helpers: `validate_option`, `validate_keys`, `validate_number`, `validate_regex`, `validate_path`, `validate_config_param`, `validate_ipv4_addr`, `validate_peers_list`, `check_xml_profile_type`, `seed_rmw_tree`, `log_and_echo`, `source_ros`. Sourced by every other script. |
| `local-ros/ros_setup.sh` | Sources `${SNAP_COMMON}/ros.env` then `exec`s "$@" — used as a command-chain wrapper for ROS apps. |
| `local-ros/{start,stop,restart}_launcher.sh` | systemctl-via-snapctl thin wrappers. |
| `local-ros/check_daemon_running.sh` | Small probe used by app commands. |
| `local-ros/rmw/fastdds/*.xml` | FastDDS profile XMLs — used when `ros.transport=fastdds/<name>` or legacy `udp` / `shm` / `udp-lo`. |
| `local-ros/rmw/cyclonedds/*.xml` | CycloneDDS profile XMLs — used when `ros.transport=cyclonedds/<name>` or legacy `udp-lo-cyclone`. |
| `local-ros/rmw/zenoh/*.json5` | Zenoh session configs (`default.json5`, `shm.json5`) — gated behind `HSC_ALLOW_ZENOH=1`; see "Zenoh status" below. |
| `local-ros/rmw/zenoh-router/*.json5` | Zenoh router configs (`default-router.json5`, `shm-router.json5`) — selected by basename to match the session profile; same gate. |
| `local-ros/zenoh_router_launcher.sh` | `rmw_zenohd` launcher for the zenoh-router service (consumer snaps that run a router app). |

## `ros.transport` grammar (current, 0.6.0+)

The validator in `configure_hook_ros.sh` accepts (zenoh tokens additionally require `HSC_ALLOW_ZENOH=1` — see "Zenoh status"):

**Legacy short tokens (kept for back-compat):**
- `udp` → `rmw/fastdds/udp.xml`
- `shm` → `rmw/fastdds/shm.xml`
- `udp-lo` → `rmw/fastdds/udp-lo.xml`
- `udp-lo-cyclone` → `rmw/cyclonedds/udp-lo.xml`

**RMW-only tokens (no profile, use library defaults):**
- `rmw_fastrtps_cpp`
- `rmw_cyclonedds_cpp`
- `rmw_zenoh_cpp` / `zenoh` (only when `HSC_ALLOW_ZENOH=1`)

**Canonical `<kind>/<name>` form:**
- `fastdds/<name>` → `${SNAP_COMMON}/rmw/fastdds/<name>.xml`
- `cyclonedds/<name>` → `${SNAP_COMMON}/rmw/cyclonedds/<name>.xml`
- `zenoh/<name>` → `${SNAP_COMMON}/rmw/zenoh/<name>.json5` (only when `HSC_ALLOW_ZENOH=1`)

**Fallback (back-compat for operator-uploaded files):**
- `<X>` → `${SNAP_COMMON}/dds-config-<X>.xml` (existing flat-path uploads still work; `check_xml_profile_type` auto-detects FastDDS vs Cyclone)

The hook writes one of two env-var combos to `${SNAP_COMMON}/ros.env`:

| Kind | RMW_IMPLEMENTATION | Other env |
|---|---|---|
| fastdds | `rmw_fastrtps_cpp` | `FASTRTPS_DEFAULT_PROFILES_FILE=<path>` (if a profile is set) |
| cyclonedds | `rmw_cyclonedds_cpp` | `CYCLONEDDS_URI=file://<path>` (if a profile is set) |
| zenoh | `rmw_zenoh_cpp` | `ZENOH_SESSION_CONFIG_URI=<path>` + `ZENOH_ROUTER_CONFIG_URI=<…-router.json5>` (if a profile is set) + `ZENOH_ROUTER_CHECK_ATTEMPTS=10` |

Variables for the other kinds are `unset` so the daemon never sees stale config.

## Zenoh status

`ros.transport=zenoh*` (any of `zenoh`, `zenoh/<name>`, `rmw_zenoh_cpp`) is **gated behind `HSC_ALLOW_ZENOH=1`**. By default (`HSC_ALLOW_ZENOH` unset) the validator rejects those tokens with an error message pointing at the bridge blocker. A consumer whose bridge is itself rclcpp-based opts in by exporting `HSC_ALLOW_ZENOH=1` from its `configure` hook *before* sourcing `configure_hook_ros.sh`; the zenoh case then resolves `zenoh/<name>` to the session profile (`rmw/zenoh/<name>.json5`) plus the matching `<name>-router.json5` and emits the `ZENOH_*` env block.

Why the default-off: `micro_ros_agent` in the rosbot snap is statically linked to FastDDS (`readelf -d` shows it has DT_NEEDED on `libfastrtps.so.2.14` but no `librmw_implementation.so`). It ignores `RMW_IMPLEMENTATION` and publishes `_motors/feedback` / `_imu/data` to the FastDDS graph only. Under `rmw_zenoh_cpp`, `ros2_control_node` never sees those topics → `RosbotSystem::on_activate()` times out (25 s) → `ros2_control_node` SIGABRTs → daemon death loop. The `zenoh-plugin-ros2dds` bridge doesn't help (it uses an incompatible zenoh key scheme).

So the rosbot snap leaves `HSC_ALLOW_ZENOH` unset on its default `micro_ros_agent` path and only sets it on the `driver.backend=mavlink` path (where the bridge is `rosbot_mavlink_bridge`, an rclcpp node that honours the active RMW). The factory configs under `local-ros/rmw/zenoh{,-router}/` ship in every snap and are live wherever the gate is set.

## How `rosbot-snap` (the consumer) pulls this in

In `rosbot-snap/snapcraft_template.yaml.jinja2` under `parts.husarion-snap-common`:

```yaml
husarion-snap-common:
  plugin: dump
  source: https://github.com/husarion/husarion-snap-common
  source-branch: "0.6.0"
  source-type: git
  organize:
    'local-ros/*.sh': usr/bin/
    'local-ros/rmw/fastdds/*.xml': usr/share/husarion-snap-common/config/rmw/fastdds/
    'local-ros/rmw/cyclonedds/*.xml': usr/share/husarion-snap-common/config/rmw/cyclonedds/
    'local-ros/rmw/zenoh/*.json5': usr/share/husarion-snap-common/config/rmw/zenoh/
    'local-ros/rmw/zenoh-router/*.json5': usr/share/husarion-snap-common/config/rmw/zenoh-router/
    'local-ros/ros.env': usr/share/husarion-snap-common/config/
```

Result inside the consuming snap:
- Hooks/utilities at `$SNAP/usr/bin/` — invoked from `snap/hooks/{configure,install}` via `source $SNAP/usr/bin/utils.sh`.
- Factory configs at `$SNAP/usr/share/husarion-snap-common/config/rmw/<kind>/`.
- `install_hook_ros.sh` copies the factory tree into `$SNAP_COMMON/rmw/` on first install.

## Local-dev iteration loop (with `rosbot-snap`)

Snapcraft supports `source-type: local` for in-repo testing. In `rosbot-snap`'s snapcraft template:

```yaml
husarion-snap-common:
  plugin: dump
  source: ../husarion-snap-common
  source-type: local
```

Then from `rosbot-snap/`: `just rebuild jazzy`. This re-renders the snapcraft.yaml, packs, unsquashfs's the resulting .snap, and `snap try`'s it. Changes to `local-ros/*.sh` propagate to a re-installed snap within a build cycle.

For production release: bump the `source-branch` back to a tagged version (e.g. `"0.6.0"`).

## Versioning + release

Currently no formal CHANGELOG. Tags follow `0.X.Y` (latest: `0.11.0`). `0.5.0` is the last "flat dds-config-*.xml" layout. `0.6.0` introduces the `rmw/` tree + canonical `<kind>/<name>` tokens, with `zenoh*` gated at the validator. `0.8.0`+ adds the `husarion-agent/` shared substrate (see README); later tags add the files-first launcher + content-interface chaining (drop the v2 capabilities substrate). Consumers pin a specific tag via `source-branch`.

## Testing surface

The validator helpers in `utils.sh` are pure shell — testable by sourcing the file in a `bash` repl and calling them with `snapctl` mocked. The transport resolution in `configure_hook_ros.sh` is exercised end-to-end via `snap set rosbot ros.transport=<X>` on a test host (see `rosbot-snap/justfile`'s `rebuild` recipe for a one-host loop). There are no automated tests checked in — hardware-side validation matters more than mocked unit tests.
