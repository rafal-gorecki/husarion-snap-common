#!/bin/bash -e

# Define a function to log and echo messages
log_and_echo() {
    local message="$*"
    local script_name=$(basename "$0")
    # Log the message with logger
    logger -t "${SNAP_NAME}" "${script_name}: $message"
    # Echo the message to standard error
    echo -e "$message" >&2
}

log() {
    local message="$*"
    local script_name=$(basename "$0")
    # Log the message with logger
    logger -t "${SNAP_NAME}" "${script_name}: $message"
}

is_integer() {
  expr "$1" : '-\?[0-9][0-9]*$' >/dev/null 2>&1
}

process_args() {
    allow_unset=false
    additional_args=()

    for arg in "$@"; do
        if [ "$arg" == "--allow-unset" ]; then
            allow_unset=true
        else
            additional_args+=("$arg")
        fi
    done

    # Return results
    echo "$allow_unset"
    echo "${additional_args[@]}"
}

# Function to validate the option values
validate_option() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local opt="${args[0]}"
    local valid_options=("${!args[1]}")

    local value="$(snapctl get ${opt})"

    if [ -z "$value" ] || [ "$value" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${opt}' cannot be unset."
            exit 1
        fi
    fi

    # Create an associative array to check valid options
    declare -A valid_options_map
    for option in "${valid_options[@]}"; do
        valid_options_map["$option"]=1
    done

    # Join the valid options with newlines
    local joined_options=$(printf "%s\n" "${valid_options[@]}")

    if [ -n "${value}" ]; then
        if [[ -z "${valid_options_map[$value]}" ]]; then
            log_and_echo "'${value}' is not a supported value for '${opt}' parameter. Possible values are:\n${joined_options}"
            exit 1
        fi
    fi
}

# Function to validate configuration keys
validate_keys() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local top_level_key="${args[0]}"
    local valid_keys=("${!args[1]}")

    # Get the current configuration for the top-level key
    local config=$(snapctl get "$top_level_key")

    # Check if the top-level key is set to a non-object value
    if ! $(echo "$config" | yq 'type == "!!map"'); then
        log_and_echo "'${top_level_key}' must be an object with valid subkeys. Setting a value directly to '${top_level_key}' is not allowed."
        exit 1
    fi

    # Get the current configuration keys
    local config_keys=$(echo "$config" | yq '. | keys' | sed 's/- //g' | tr -d '"')

    if [ -z "$config_keys" ] || [ "$config_keys" == "[]" ] || [ "$value" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${top_level_key}' cannot be unset."
            exit 1
        fi
    fi

    # Create an associative array to check valid keys
    declare -A valid_keys_map
    for key in "${valid_keys[@]}"; do
        valid_keys_map["$key"]=1
    done

    # Join the valid options with newlines
    local joined_options=$(printf "%s\n" "${valid_keys[@]}")

    # Iterate over the keys in the configuration
    for key in $config_keys; do
        # Check if the key is in the list of valid keys
        if [[ -z "${valid_keys_map[$key]}" ]]; then
            log_and_echo "'${key}' is not a supported value for '${top_level_key}' key. Possible values are:\n${joined_options}"
            exit 1
        fi
    done
}

validate_number() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local value_key="${args[0]}"
    local range=("${!args[1]}")
    local excluded_values=("${!args[2]:-}")

    # Get the value using snapctl
    local value=$(snapctl get "$value_key")

    if [ -z "$value" ] || [ "$value" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${opt}' cannot be unset."
            exit 1
        fi
    fi

    # Extract the min and max range values
    local min_value=${range[0]}
    local max_value=${range[1]}

    # Join the excluded values with newlines if they exist
    local joined_excluded_values
    local exclude_message
    if [ -n "$excluded_values" ]; then
        joined_excluded_values=$(printf "%s\n" "${excluded_values[@]}")
        exclude_message=" excluding:\n${joined_excluded_values[*]}"
    else
        exclude_message=""
    fi

    # Check if the value is an integer
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_and_echo "'${value}' is not a supported value for '${value_key}'. Possible values are integers between ${min_value} and ${max_value}. ${exclude_message}"
        exit 1
    fi

    # Check if the value is in the valid range
    if [ "$value" -lt "$min_value" ] || [ "$value" -gt "$max_value" ]; then
        log_and_echo "'${value}' is not a supported value for '${value_key}'. Possible values are integers between ${min_value} and ${max_value}. ${exclude_message}"
        exit 1
    fi

    # Check if the value is in the excluded list
    if [ -n "$excluded_values" ]; then
        for excluded_value in "${excluded_values[@]}"; do
            if [ "$value" -eq "$excluded_value" ]; then
                log_and_echo "'${value}' is not a supported value for '${value_key}'. Possible values are integers between ${min_value} and ${max_value}. ${exclude_message}"
                exit 1
            fi
        done
    fi
}

validate_float() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local value_key="${args[0]}"

    # Get the value using snapctl
    local value=$(snapctl get "$value_key")

    if [ -z "$value" ] || [ "$value" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${value_key}' cannot be unset."
            exit 1
        fi
    fi

    # Check if the value is a floating-point number
    if ! [[ "$value" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
        log_and_echo "'${value}' is not a supported value for '${value_key}'. Possible values are floating-point numbers."
        exit 1
    fi
}

validate_regex() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local value_key="${args[0]}"
    local regex="${args[1]}"

    # Get the value using snapctl
    local value=$(snapctl get "$value_key")

    if [ -z "$value" ] || [ "$value" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${value_key}' cannot be unset."
            exit 1
        fi
    fi

    # Check if the value matches the regex
    if ! [[ "$value" =~ $regex ]]; then
        log_and_echo "'${value}' is not a supported value for '${value_key}'. It must match the regex pattern: ${regex}"
        exit 1
    fi
}

validate_path() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local path_key="${args[0]}"
    local regex="${args[1]}"
    local valid_options=("${!args[2]:-}")

    # Get the value using snapctl
    local config_value=$(snapctl get "$path_key")

    if [ -z "$config_value" ] || [ "$config_value" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${path_key}' cannot be unset."
            exit 1
        fi
    fi

    # Check if the value matches any of the valid options
    for option in "${valid_options[@]}"; do
        if [ "$config_value" == "$option" ]; then
            return 0
        fi
    done

    # Check if the value matches the regex pattern or is a valid file path
    if [[ ! "$config_value" =~ $regex ]] && [ ! -f "$config_value" ]; then
        log_and_echo "'${config_value}' is not a valid value for '${path_key}'. It must match the regex '${regex}', be a valid file path, or be one of the following values: ${valid_options[@]}"
        exit 1
    fi
}

# Universal function to validate configuration parameter based on regex and optional hardcoded values
validate_config_param() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local param_key="${args[0]}"
    local regex_template="${args[1]}"
    local hardcoded_values=("${!args[2]:-}")

    # Get the param-key value using snapctl
    local param_value=$(snapctl get "$param_key")

    # Check if the param_value is empty
    if [ -z "$param_value" ] || [ "$param_value" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${param_key}' cannot be unset."
            exit 1
        fi
    fi

    # Form the regex using the param_value
    local regex=$(echo "$regex_template" | sed "s/VALUE/${param_value}/g")

    # Extract the prefix and suffix from the regex template
    local prefix=$(echo "$regex_template" | sed 's/VALUE.*//')
    local suffix=$(echo "$regex_template" | sed 's/.*VALUE//')

    # Check if the param_value matches any of the hardcoded values
    for value in "${hardcoded_values[@]}"; do
        if [ "$param_value" == "$value" ]; then
            return 0
        fi
    done

    # Capture the list of files matching the regex template (excluding the value)
    local available_files=($(ls "${SNAP_COMMON}/" | grep -E "$(echo "$regex_template" | sed 's/VALUE/.*/g')" | sed -E "s/^${prefix}(.*)${suffix}$/\1/"))

    # Merge hardcoded values and available files into a single list
    local all_options=("${hardcoded_values[@]}" "${available_files[@]}")
    local joined_options=$(printf "%s\n" "${all_options[@]}")

    # Check if the file matching the regex exists in ${SNAP_COMMON}
    if ls "${SNAP_COMMON}/" | grep -qE "$regex"; then
        return 0
    else
        log_and_echo "'${param_value}' is not a valid value for '${param_key}'. There is no '${SNAP_COMMON}/$regex'. Available options:\n${joined_options[@]}"
        exit 1
    fi
}

validate_ipv4_addr() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local value_key="${args[0]}"

    # Get the value using snapctl
    local ip_address=$(snapctl get "$value_key")
    local ip_address_regex='^(([0-9]{1,3}\.){3}[0-9]{1,3})$'

    if [ -z "$ip_address" ] || [ "$ip_address" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${value_key}' cannot be unset."
            exit 1
        fi
    fi

    if [[ "$ip_address" =~ $ip_address_regex ]]; then
        # Split the IP address into its parts
        IFS='.' read -r -a octets <<< "$ip_address"

        # Check each octet
        for octet in "${octets[@]}"; do
            if ((octet < 0 || octet > 255)); then
                log_and_echo "Invalid format for '$value_key'. Each part of the IPv4 address must be between 0 and 255. Received: '$ip_address'."
                exit 1
            fi
        done
    else
        log_and_echo "Invalid format for '$value_key'. Expected format: a valid IPv4 address. Received: '$ip_address'."
        exit 1
    fi
}

# Function to validate IPv6 addresses
validate_ipv6_addr() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local value_key="${args[0]}"

    # Get the value using snapctl
    local ip_address=$(snapctl get "$value_key")
    local ip_address_regex='^([0-9a-fA-F]{1,4}:){7}([0-9a-fA-F]{1,4})$'

    if [ -z "$ip_address" ] || [ "$ip_address" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${value_key}' cannot be unset."
            exit 1
        fi
    fi

    if [[ "$ip_address" =~ $ip_address_regex ]]; then
        return 0
    else
        log_and_echo "Invalid format for '$value_key'. Expected format: a valid IPv6 address. Received: '$ip_address'."
        exit 1
    fi
}

# Function to validate hostnames
validate_hostname() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local value_key="${args[0]}"

    # Get the value using snapctl
    local hostname=$(snapctl get "$value_key")
    local hostname_regex='^([a-zA-Z0-9-_]+\.)*[a-zA-Z0-9-_]+\.[a-zA-Z]{2,}$'

    if [ -z "$hostname" ] || [ "$hostname" == "''" ]; then
        if $allow_unset; then
            return 0
        else
            log_and_echo "'${value_key}' cannot be unset."
            exit 1
        fi
    fi

    if [[ "$hostname" =~ $hostname_regex ]]; then
        if grep -q "$hostname" /etc/hosts; then
            return 0
        else
            log_and_echo "Hostname '$hostname' not found in /etc/hosts."
            exit 1
        fi
    else
        log_and_echo "Invalid format for '$value_key'. Expected format: a valid hostname. Received: '$hostname'."
        exit 1
    fi
}

# Function to validate the peers list
validate_peers_list() {
    local input=($(process_args "$@"))
    local allow_unset="${input[0]}"
    local args=("${input[@]:1}")

    local value_key="${args[0]}"

    # Get the peers list using snapctl
    local peers_list=$(snapctl get "$value_key")

    # Check if peers list is empty
    if [ -z "$peers_list" ] || [ "$peers_list" == "''" ]; then
        if $allow_unset; then
            log_and_echo "Peers list is empty."
            return 0
        else
            log_and_echo "'${value_key}' cannot be unset."
            exit 1
        fi
    fi

    local ip_v4_regex='^(([0-9]{1,3}\.){3}[0-9]{1,3})$'
    local ip_v6_regex='^([0-9a-fA-F]{1,4}:){7}([0-9a-fA-F]{1,4})$'
    local hostname_regex='^[0-9a-z_-]{1,20}$'

    # Split the peers list by semicolon and validate each entry
    IFS=';' read -ra peers <<< "$peers_list"
    for peer in "${peers[@]}"; do
        if [[ "$peer" =~ $ip_v4_regex ]]; then
            # Validate IPv4 address
            IFS='.' read -r -a octets <<< "$peer"
            for octet in "${octets[@]}"; do
                if ((octet < 0 || octet > 255)); then
                    log_and_echo "Invalid IPv4 address: '$peer'. Each part must be between 0 and 255."
                    exit 1
                fi
            done
        elif [[ "$peer" =~ $ip_v6_regex ]]; then
            # Validate IPv6 address
            # IPv6 regex already ensures valid format
            :
        elif [[ "$peer" =~ $hostname_regex ]]; then
            # Validate hostname
            # configure hook needs 'network-bind' interface for that
            if ! grep -qE "^[^#]*\s+$peer(\s|$)" /etc/hosts; then
                log_and_echo "Hostname '$peer' not found in /etc/hosts."
                exit 1
            fi
        else
            log_and_echo "Invalid address: '$peer'. Must be a valid IPv4, IPv6 address or a hostname listed in /etc/hosts."
            exit 1
        fi
    done
}

# Function to find the ttyUSB* or /dev/video* device for the specified USB Vendor and Product ID
find_usb_device() {
    local args=("$@")
    local device_type="${args[0]}" # new parameter to specify device type
    local port_param="${args[1]}"
    local vendor_id="${args[2]}"
    local product_id="${args[3]}"

    # Get the serial-port or video-device value using snapctl
    local device_port=$(snapctl get "$port_param")

    if [ "$device_port" == "auto" ]; then
        for device in /sys/bus/usb/devices/*; do
            if [ -f "$device/idVendor" ]; then
                current_vendor_id=$(cat "$device/idVendor")
                if [ "$current_vendor_id" == "$vendor_id" ]; then
                    if [ -z "$product_id" ] || ([ -f "$device/idProduct" ] && [ "$(cat "$device/idProduct")" == "$product_id" ]); then
                        # Look for specified device type in the subdirectories
                        for subdir in "$device/"*; do
                            if [ -d "$subdir" ]; then
                                if [ "$device_type" == "ttyUSB" ]; then
                                    search_pattern="ttyUSB[0-9]+"
                                elif [ "$device_type" == "video" ]; then
                                    search_pattern="video[0-9]+"
                                else
                                    echo "Error: Unknown device type '$device_type'"
                                    return 1
                                fi

                                for dev in $(find "$subdir" -regextype posix-egrep -regex ".*/$search_pattern" -print 2>/dev/null); do
                                    if [ -e "$dev" ]; then
                                        dev_name=$(basename "$dev")
                                        dev_path="/dev/$dev_name"
                                        # Additional validation based on device type
                                        if [[ "$device_type" == "video" && "$dev_name" =~ ^video[0-9]+$ ]]; then
                                            # Check if the video device supports video formats
                                            if v4l2-ctl --list-formats --device "$dev_path" | grep -qE '\[[0-9]\]'; then
                                                echo "$dev_path"
                                                return 0
                                            fi
                                        elif [[ "$device_type" == "ttyUSB" && "$dev_name" =~ ^ttyUSB[0-9]+$ ]]; then
                                            # Simple validation for ttyUSB devices
                                            echo "$dev_path"
                                            return 0
                                        fi
                                    fi
                                done
                            fi
                        done
                    fi
                fi
            fi
        done
        echo "Error: Device with ID $vendor_id:${product_id:-*} not found."
        return 1
    else
        echo "$device_port"
        return 0
    fi
}

source_ros() {
    if [ -d "$SNAP/opt/ros/jazzy" ]; then
        source $SNAP/opt/ros/jazzy/setup.bash 2>/dev/null
    elif [ -d "$SNAP/opt/ros/humble" ]; then
        source $SNAP/opt/ros/humble/setup.bash 2>/dev/null
    else
        log_and_echo "No compatible ROS 2 distribution found"
        exit 1
    fi
}

# Seed ${SNAP_COMMON}/rmw/ from the snap's factory snapshot. Idempotent.
# --force overwrites (install); default copies only missing files so
# operator edits survive (configure, on every refresh).
seed_rmw_tree() {
    local force=0
    [ "${1:-}" = "--force" ] && force=1

    local src="${SNAP}/usr/share/husarion-snap-common/config/rmw"
    local dst="${SNAP_COMMON}/rmw"
    [ -d "$src" ] || return 0

    mkdir -p "${dst}/fastdds" "${dst}/cyclonedds" "${dst}/zenoh" "${dst}/zenoh-router"

    local sub f name
    for sub in fastdds cyclonedds zenoh zenoh-router; do
        [ -d "${src}/${sub}" ] || continue
        for f in "${src}/${sub}"/*; do
            [ -e "$f" ] || continue
            name=$(basename "$f")
            if [ "$force" = "1" ] || [ ! -e "${dst}/${sub}/${name}" ]; then
                cp -f "$f" "${dst}/${sub}/${name}"
            fi
        done
    done

    ln -sfn rmw/fastdds/udp.xml       "${SNAP_COMMON}/dds-config-udp.xml"
    ln -sfn rmw/fastdds/shm.xml       "${SNAP_COMMON}/dds-config-shm.xml"
    ln -sfn rmw/fastdds/udp-lo.xml    "${SNAP_COMMON}/dds-config-udp-lo.xml"
    ln -sfn rmw/cyclonedds/udp-lo.xml "${SNAP_COMMON}/dds-config-udp-lo-cyclone.xml"
}

# Function to check the type of the provided XML file
check_xml_profile_type() {
    local xml_file="$1"

    if [[ ! -f "$xml_file" ]]; then
        log_and_echo "File '$xml_file' does not exist."
        return 1
    fi

    local root_element
    local namespace

    # Extract the root element
    root_element=$(yq '. | keys | .[1]' "$xml_file")

    # Extract the namespace based on the root element
    if [[ "$root_element" == "CycloneDDS" ]]; then
        namespace=$(yq .CycloneDDS."+@xmlns" "$xml_file")
    elif [[ "$root_element" == "profiles" ]]; then
        namespace=$(yq .profiles."+@xmlns" "$xml_file")
    else
        namespace="unknown"
    fi

    # Remove quotes from the extracted values
    root_element=${root_element//\"/}
    namespace=${namespace//\"/}

    if [[ "$root_element" == "profiles" ]] && [[ "$namespace" == "http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles" ]]; then
        echo "rmw_fastrtps_cpp"
    elif [[ "$root_element" == "CycloneDDS" ]] && [[ "$namespace" == "https://cdds.io/config" ]]; then
        echo "rmw_cyclonedds_cpp"
    else
        exit 1
    fi
}

