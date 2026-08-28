#!/usr/bin/env bash
# Apache Cloudberry interactive installation and cluster operations tool.
# This script intentionally uses the official gp utilities for database
# lifecycle operations. It does not manage individual postgres processes.

set -uo pipefail

###############################################################################
# Globals and defaults
###############################################################################

init_globals() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONF_DIR="${SCRIPT_DIR}/conf"
    LOG_DIR="${SCRIPT_DIR}/logs"
    LOG_FILE="${LOG_DIR}/cloudberry_tool.log"
    INSTALL_CONF="${CONF_DIR}/install.conf"
    CLUSTER_ENV_FILE="${CONF_DIR}/cluster-env.sh"
    HOSTFILE="${CONF_DIR}/hostfile"
    GPINIT_HOSTFILE="${CONF_DIR}/hostfile_gpinitsystem"
    GPINIT_CONFIG="${CONF_DIR}/gpinitsystem_config"
    GPINIT_INPUT="${CONF_DIR}/gpinitsystem_input"
    SSH_CONFIG="${CONF_DIR}/ssh_config"
    SSH_WRAPPER_DIR="${CONF_DIR}/ssh-bin"

    CBDB_USER="gpadmin"
    # Prefer an environment prepared by cloudberry-env.sh. Fall back to the
    # postgres found in PATH, then to a user-writable installation path.
    CBDB_HOME="${GPHOME:-}"
    if [[ -z "$CBDB_HOME" ]]; then
        local detected_postgres=""
        detected_postgres="$(command -v postgres 2>/dev/null || true)"
        if [[ -n "$detected_postgres" && "$detected_postgres" == */bin/postgres ]]; then
            CBDB_HOME="$(cd "$(dirname "$detected_postgres")/.." && pwd -P)"
        else
            CBDB_HOME="${HOME}/cloudberry-install"
        fi
    fi
    CBDB_DATA_HOME="/data/cloudberry"
    COORDINATOR_HOST=""
    COORDINATOR_IP=""
    COORDINATOR_PORT=5432
    COORDINATOR_DIRECTORY="/data/cloudberry/coordinator"
    COORDINATOR_DATA_DIRECTORY="/data/cloudberry/coordinator/gpseg-1"
    STANDBY_ENABLED="false"
    STANDBY_HOST=""
    STANDBY_DATA_DIRECTORY=""
    SEGMENT_PORT_BASE=6000
    SEGMENT_DATA_DIRECTORY="/data/cloudberry/primary"
    MIRROR_ENABLED="false"
    MIRROR_MODE="group"
    MIRROR_PORT_BASE=7000
    MIRROR_DATA_DIRECTORY="/data/cloudberry/mirror"
    SEGMENTS_PER_HOST=1
    DATABASE_NAME="postgres"
    SEG_PREFIX="gpseg"
    INSTALL_MODE=""
    INSTALL_STATE="planned"
    CONFIG_VERSION=2
    INITIAL_HEALTH_TIMEOUT=180
    INITIAL_HEALTH_INTERVAL=3

    DRY_RUN="false"
    CURRENT_STAGE=""
    READ_VALUE=""
    PARSED_COORDINATOR=""
    PORT_PROBE_STATE=""
    CLUSTER_RUNTIME_STATE="UNKNOWN"
    CLUSTER_RUNTIME_TOTAL=0
    CLUSTER_RUNTIME_LISTENING=0

    HOSTS=()
    SEGMENT_HOSTS=()
    PRIMARY_SEGMENTS=()
    MIRROR_SEGMENTS=()
    declare -gA HOST_IP=()
    declare -gA HOST_PORT=()
    declare -gA HOST_PROXY_JUMP=()
    declare -gA HOST_ROLE=()
    declare -gA HOST_SEEN=()
    declare -gA IP_SEEN=()
}

init_runtime_directories() {
    if ! mkdir -p -- "$CONF_DIR" "$LOG_DIR"; then
        printf 'ERROR: cannot create runtime directories under %s\n' "$SCRIPT_DIR" >&2
        return 1
    fi
    if ! touch -- "$LOG_FILE"; then
        printf 'ERROR: cannot write log file: %s\n' "$LOG_FILE" >&2
        return 1
    fi
    chmod 700 "$CONF_DIR" "$LOG_DIR" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

###############################################################################
# Logging and command execution
###############################################################################

log_line() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s [%s] %s\n' "$timestamp" "$level" "$message" | tee -a "$LOG_FILE"
}

log_info()    { log_line "INFO" "$*"; }
log_warn()    { log_line "WARN" "$*"; }
log_error()   { log_line "ERROR" "$*" >&2; }
log_success() { log_line "OK" "$*"; }

log_file_detail() {
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s [DETAIL] %s\n' "$timestamp" "$message" >> "$LOG_FILE"
}

format_command() {
    local output=""
    local arg quoted
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        output+="${output:+ }${quoted}"
    done
    printf '%s' "$output"
}

run_labeled_command() {
    local display="$1"
    shift
    local full_command
    full_command="$(format_command "$@")"
    log_info "Command: ${display}"
    if [[ "$full_command" != "$display" ]]; then
        log_file_detail "Full command: ${full_command}"
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[DRY-RUN] %s\n' "$full_command"
        return 0
    fi

    "$@" 2>&1 | tee -a "$LOG_FILE"
    local status=${PIPESTATUS[0]}
    if (( status != 0 )); then
        log_error "Command failed with exit code ${status}: ${display}"
        return "$status"
    fi
    return 0
}

run_command() {
    local display
    display="$(format_command "$@")"
    run_labeled_command "$display" "$@"
}

run_gp_command() {
    local gp_path="${SSH_WRAPPER_DIR}:${CBDB_HOME}/bin:${PATH}"
    local gp_lib="${CBDB_HOME}/lib"
    local gp_python="${CBDB_HOME}/lib/python"
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        gp_lib+="${gp_lib:+:}${LD_LIBRARY_PATH}"
    fi
    if [[ -n "${PYTHONPATH:-}" ]]; then
        gp_python+="${gp_python:+:}${PYTHONPATH}"
    fi
    run_command env \
        "GPHOME=${CBDB_HOME}" \
        "COORDINATOR_DATA_DIRECTORY=${COORDINATOR_DATA_DIRECTORY}" \
        "PGPORT=${COORDINATOR_PORT}" \
        "USER=${CBDB_USER}" \
        "LOGNAME=${CBDB_USER}" \
        "PATH=${gp_path}" \
        "LD_LIBRARY_PATH=${gp_lib}" \
        "PYTHONPATH=${gp_python}" \
        "$@"
}

capture_gp_command() {
    local gp_path="${SSH_WRAPPER_DIR}:${CBDB_HOME}/bin:${PATH}"
    local gp_lib="${CBDB_HOME}/lib"
    local gp_python="${CBDB_HOME}/lib/python"
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        gp_lib+="${gp_lib:+:}${LD_LIBRARY_PATH}"
    fi
    if [[ -n "${PYTHONPATH:-}" ]]; then
        gp_python+="${gp_python:+:}${PYTHONPATH}"
    fi
    env \
        "GPHOME=${CBDB_HOME}" \
        "COORDINATOR_DATA_DIRECTORY=${COORDINATOR_DATA_DIRECTORY}" \
        "PGPORT=${COORDINATOR_PORT}" \
        "USER=${CBDB_USER}" \
        "LOGNAME=${CBDB_USER}" \
        "PATH=${gp_path}" \
        "LD_LIBRARY_PATH=${gp_lib}" \
        "PYTHONPATH=${gp_python}" \
        "$@" 2>>"$LOG_FILE"
}

quote_remote_command() {
    local output=""
    local arg quoted
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        output+="${output:+ }${quoted}"
    done
    REPLY="$output"
}

summarize_remote_command() {
    local command_name="${1:-command}"
    if [[ "$command_name" == "bash" && "${2:-}" == "-c" ]]; then
        local argument_summary=""
        if (( $# > 4 )); then
            argument_summary="$(format_command "${@:5}")"
        fi
        printf 'bash -c <remote script>%s' "${argument_summary:+ -- ${argument_summary}}"
        return
    fi
    format_command "$@"
}

run_remote() {
    local host="$1"
    shift
    local summary
    summary="$(summarize_remote_command "$@")"
    quote_remote_command "$@"
    run_labeled_command "Remote command [${host}]: ${summary}" \
        "${SSH_WRAPPER_DIR}/ssh" -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$REPLY"
}

remote_test() {
    local host="$1"
    shift
    quote_remote_command "$@"
    "${SSH_WRAPPER_DIR}/ssh" -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$REPLY" \
        >/dev/null 2>>"$LOG_FILE"
}

capture_remote() {
    local host="$1"
    shift
    quote_remote_command "$@"
    local output
    if ! output="$("${SSH_WRAPPER_DIR}/ssh" -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$REPLY" 2>>"$LOG_FILE")"; then
        return 1
    fi
    printf '%s\n' "$output"
}

print_stage() {
    local number="$1"
    local total="$2"
    local message="$3"
    CURRENT_STAGE="$message"
    printf '\n[%s/%s] %s\n' "$number" "$total" "$message"
    log_info "Stage ${number}/${total}: ${message}"
}

###############################################################################
# Input helpers and validation
###############################################################################

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_string() {
    local prompt="$1"
    local default_value="${2:-}"
    local value
    if [[ -n "$default_value" ]]; then
        read -r -p "${prompt} [${default_value}]: " value || return 1
        value="$(trim "$value")"
        [[ -z "$value" ]] && value="$default_value"
    else
        read -r -p "${prompt}: " value || return 1
        value="$(trim "$value")"
    fi
    READ_VALUE="$value"
}

read_int() {
    local prompt="$1"
    local default_value="$2"
    local minimum="$3"
    local maximum="$4"
    local value
    while true; do
        read_string "$prompt" "$default_value" || return 1
        value="$READ_VALUE"
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= minimum && value <= maximum )); then
            READ_VALUE="$value"
            return 0
        fi
        log_error "请输入 ${minimum}-${maximum} 范围内的整数"
    done
}

confirm() {
    local prompt="$1"
    local default_answer="${2:-N}"
    local answer suffix
    if [[ "$default_answer" == "Y" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi
    read -r -p "${prompt} ${suffix}: " answer || return 1
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
        [[ "$default_answer" == "Y" ]]
        return
    fi
    [[ "$answer" == "y" || "$answer" == "yes" ]]
}

require_phrase() {
    local prompt="$1"
    local expected="$2"
    local answer
    printf '%s\n' "$prompt"
    read -r -p "Type ${expected} to continue: " answer || return 1
    [[ "$answer" == "$expected" ]]
}

validate_ip() {
    local ip="$1"
    local IFS='.'
    local -a octets=()
    read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    local octet
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
}

validate_hostname() {
    local hostname_value="$1"
    [[ ${#hostname_value} -le 253 ]] || return 1
    [[ "$hostname_value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$hostname_value" != *..* ]] || return 1
    local IFS='.'
    local -a labels=()
    read -r -a labels <<< "$hostname_value"
    local label
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_path() {
    local path="$1"
    [[ "$path" == /* ]] || return 1
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    [[ "$path" != "/" && "$path" != *"/../"* && "$path" != */.. ]] || return 1
    [[ "$path" != *"//"* ]] || return 1
}

validate_install_path() {
    local path="$1"
    validate_path "$path" || return 1
    case "$(canonicalize_path "$path")" in
        /usr|/usr/local|/opt|/home|/var|/etc|"$HOME"|"$SCRIPT_DIR") return 1 ;;
    esac
}

validate_data_root() {
    local path="$1"
    validate_path "$path" || return 1
    case "$(canonicalize_path "$path")" in
        /usr|/usr/local|/opt|/home|/var|/etc|"$HOME"|"$SCRIPT_DIR"|"$CBDB_HOME") return 1 ;;
    esac
}

validate_database_name() {
    local name="$1"
    [[ ${#name} -le 63 ]] || return 1
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]
}

validate_username() {
    local name="$1"
    [[ ${#name} -le 32 ]] || return 1
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

validate_proxy_jump() {
    local value="$1"
    [[ -z "$value" ]] && return 0
    [[ "$value" =~ ^[A-Za-z0-9._@,:-]+$ ]] || return 1

    local IFS=','
    local -a jumps=()
    read -r -a jumps <<< "$value"
    local jump user_host user="" host_port host port=""
    for jump in "${jumps[@]}"; do
        [[ -n "$jump" ]] || return 1
        user_host="$jump"
        user=""
        if [[ "$user_host" == *@* ]]; then
            user="${user_host%%@*}"
            user_host="${user_host#*@}"
            validate_username "$user" || return 1
        fi
        host_port="$user_host"
        host="$host_port"
        port=""
        if [[ "$host_port" == *:* ]]; then
            host="${host_port%:*}"
            port="${host_port##*:}"
            validate_port "$port" || return 1
        fi
        if ! validate_hostname "$host" && ! validate_ip "$host"; then
            return 1
        fi
    done
}

validate_role() {
    case "$1" in
        coordinator|segment|standby|coordinator,segment) return 0 ;;
        *) return 1 ;;
    esac
}

canonicalize_path() {
    local path="$1"
    while [[ "$path" != "/" && "$path" == */ ]]; do
        path="${path%/}"
    done
    printf '%s' "$path"
}

prompt_validated_string() {
    local prompt="$1"
    local default_value="$2"
    local validator="$3"
    local error_message="$4"
    while true; do
        read_string "$prompt" "$default_value" || return 1
        if "$validator" "$READ_VALUE"; then
            return 0
        fi
        log_error "$error_message"
    done
}

###############################################################################
# Host model
###############################################################################

reset_host_model() {
    HOSTS=()
    SEGMENT_HOSTS=()
    PRIMARY_SEGMENTS=()
    MIRROR_SEGMENTS=()
    HOST_IP=()
    HOST_PORT=()
    HOST_PROXY_JUMP=()
    HOST_ROLE=()
    HOST_SEEN=()
    IP_SEEN=()
    COORDINATOR_HOST=""
    COORDINATOR_IP=""
    STANDBY_HOST=""
    STANDBY_ENABLED="false"
}

add_host() {
    local hostname_value="$1"
    local ip="$2"
    local ssh_port="$3"
    local role="$4"
    local proxy_jump="${5:-}"

    validate_hostname "$hostname_value" || { log_error "无效 hostname: ${hostname_value}"; return 1; }
    validate_ip "$ip" || { log_error "无效 IPv4 地址: ${ip}"; return 1; }
    validate_port "$ssh_port" || { log_error "无效 SSH 端口: ${ssh_port}"; return 1; }
    validate_proxy_jump "$proxy_jump" || { log_error "无效 ProxyJump: ${proxy_jump}"; return 1; }
    validate_role "$role" || { log_error "无效主机角色: ${role}"; return 1; }
    [[ -z "${HOST_SEEN[$hostname_value]:-}" ]] || { log_error "hostname 重复: ${hostname_value}"; return 1; }
    local endpoint="${ip}:${ssh_port}"
    [[ -z "${IP_SEEN[$endpoint]:-}" ]] || { log_error "SSH 端点重复: ${endpoint}"; return 1; }

    HOSTS+=("${hostname_value}|${ip}|${ssh_port}|${role}|${proxy_jump}")
    HOST_IP["$hostname_value"]="$ip"
    HOST_PORT["$hostname_value"]="$ssh_port"
    HOST_PROXY_JUMP["$hostname_value"]="$proxy_jump"
    HOST_ROLE["$hostname_value"]="$role"
    HOST_SEEN["$hostname_value"]=1
    IP_SEEN["$endpoint"]="$hostname_value"
}

input_one_host() {
    local index="$1"
    local role="$2"
    local hostname_value ip ssh_port proxy_jump
    while true; do
        printf '\nHost %s (%s)\n' "$index" "$role"
        prompt_validated_string "Hostname" "" validate_hostname "hostname 格式无效" || return 1
        hostname_value="$READ_VALUE"
        prompt_validated_string "IPv4" "" validate_ip "IPv4 格式无效" || return 1
        ip="$READ_VALUE"
        read_int "SSH port" 22 1 65535 || return 1
        ssh_port="$READ_VALUE"
        while true; do
            read_string "ProxyJump ([user@]host[:port], comma-separated; blank for none)" "" || return 1
            proxy_jump="$READ_VALUE"
            validate_proxy_jump "$proxy_jump" && break
            log_error "ProxyJump 格式无效"
        done
        if add_host "$hostname_value" "$ip" "$ssh_port" "$role" "$proxy_jump"; then
            READ_VALUE="$hostname_value"
            return 0
        fi
    done
}

input_hosts() {
    local host_count="$1"
    local layout="$2"
    local index role host
    for ((index = 1; index <= host_count; index++)); do
        role="segment"
        if [[ "$layout" == "coordinator-first" && "$index" -eq 1 ]]; then
            role="coordinator"
        fi
        input_one_host "$index" "$role" || return 1
        host="$READ_VALUE"
        if [[ "$layout" == "coordinator-first" && "$index" -eq 1 ]]; then
            COORDINATOR_HOST="$host"
            COORDINATOR_IP="${HOST_IP[$host]}"
        elif [[ "$layout" == "coordinator-first" ]]; then
            SEGMENT_HOSTS+=("$host")
        fi
    done
}

host_exists() {
    [[ -n "${HOST_SEEN[$1]:-}" ]]
}

host_has_role() {
    local host="$1"
    local role="$2"
    [[ ",${HOST_ROLE[$host]:-}," == *",${role},"* ]]
}

array_contains() {
    local expected="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$expected" ]] && return 0
    done
    return 1
}

parse_host_selection() {
    local input="$1"
    local allow_empty="${2:-false}"
    local normalized="${input//,/ }"
    local -a selected=()
    local -a candidates=()
    local host
    declare -A selection_seen=()
    read -r -a candidates <<< "$normalized"
    for host in "${candidates[@]}"; do
        host_exists "$host" || { log_error "未知主机: ${host}"; return 1; }
        [[ -z "${selection_seen[$host]:-}" ]] || { log_error "主机重复: ${host}"; return 1; }
        selection_seen["$host"]=1
        selected+=("$host")
    done
    if [[ "$allow_empty" != "true" && ${#selected[@]} -eq 0 ]]; then
        log_error "主机列表不能为空"
        return 1
    fi
    SEGMENT_HOSTS=("${selected[@]}")
}

###############################################################################
# Configuration persistence
###############################################################################

serialize_array() {
    local separator="$1"
    shift
    local result=""
    local item
    for item in "$@"; do
        result+="${result:+$separator}${item}"
    done
    printf '%s' "$result"
}

find_system_command() {
    local name="$1"
    local candidate
    for candidate in "/usr/bin/${name}" "/bin/${name}" "/usr/local/bin/${name}"; do
        if [[ -x "$candidate" && "$candidate" != "${SSH_WRAPPER_DIR}/${name}" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

generate_ssh_transport_files() {
    local real_ssh real_scp real_keyscan
    real_ssh="$(find_system_command ssh)" || { log_error "System ssh command not found"; return 1; }
    real_scp="$(find_system_command scp)" || { log_error "System scp command not found"; return 1; }
    real_keyscan="$(find_system_command ssh-keyscan)" || { log_error "System ssh-keyscan command not found"; return 1; }

    mkdir -p -- "$SSH_WRAPPER_DIR" || return 1
    chmod 700 "$SSH_WRAPPER_DIR" || return 1

    local config_temp ssh_temp scp_temp keyscan_temp
    config_temp="$(mktemp "${SSH_CONFIG}.tmp.XXXXXX")" || return 1
    ssh_temp="$(mktemp "${SSH_WRAPPER_DIR}/ssh.tmp.XXXXXX")" || { rm -f -- "$config_temp"; return 1; }
    scp_temp="$(mktemp "${SSH_WRAPPER_DIR}/scp.tmp.XXXXXX")" || { rm -f -- "$config_temp" "$ssh_temp"; return 1; }
    keyscan_temp="$(mktemp "${SSH_WRAPPER_DIR}/ssh-keyscan.tmp.XXXXXX")" || {
        rm -f -- "$config_temp" "$ssh_temp" "$scp_temp"
        return 1
    }

    local ssh_user="$CBDB_USER"
    [[ "$(id -u)" == "0" ]] && ssh_user="root"
    local record host ip port role proxy_jump
    {
        printf '# Generated by cloudberry_tool.sh. Do not edit.\n'
        for record in "${HOSTS[@]}"; do
            IFS='|' read -r host ip port role proxy_jump <<< "$record"
            printf 'Host %s\n' "$host"
            printf '    HostName %s\n' "$ip"
            printf '    Port %s\n' "$port"
            printf '    User %s\n' "$ssh_user"
            [[ -n "$proxy_jump" ]] && printf '    ProxyJump %s\n' "$proxy_jump"
        done
        # Generated endpoint settings are parsed first and therefore win. The
        # user's config can still supply identities and generic SSH options.
        printf 'Host *\n'
        printf '    Include ~/.ssh/config\n'
    } > "$config_temp"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec %q -F %q "$@"\n' "$real_ssh" "$SSH_CONFIG"
    } > "$ssh_temp"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec %q -F %q "$@"\n' "$real_scp" "$SSH_CONFIG"
    } > "$scp_temp"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -u\n'
        printf 'host="${@: -1}"\n'
        printf 'args=("${@:1:$#-1}")\n'
        printf 'case "$host" in\n'
        for record in "${HOSTS[@]}"; do
            IFS='|' read -r host ip port role proxy_jump <<< "$record"
            printf '  %q)\n' "$host"
            if [[ -n "$proxy_jump" ]]; then
                printf '    printf %q >&2\n' "ssh-keyscan cannot reach ${host} through ProxyJump; establish trust with ssh first.\n"
                printf '    exit 2\n'
            else
                printf '    exec %q "${args[@]}" -p %q %q\n' "$real_keyscan" "$port" "$ip"
            fi
            printf '    ;;\n'
        done
        printf '  *) exec %q "$@" ;;\n' "$real_keyscan"
        printf 'esac\n'
    } > "$keyscan_temp"

    chmod 600 "$config_temp" || return 1
    chmod 700 "$ssh_temp" "$scp_temp" "$keyscan_temp" || return 1
    mv -f -- "$config_temp" "$SSH_CONFIG" || return 1
    mv -f -- "$ssh_temp" "${SSH_WRAPPER_DIR}/ssh" || return 1
    mv -f -- "$scp_temp" "${SSH_WRAPPER_DIR}/scp" || return 1
    mv -f -- "$keyscan_temp" "${SSH_WRAPPER_DIR}/ssh-keyscan" || return 1
    log_success "SSH transport configuration generated: ${SSH_CONFIG}"
}

validate_ssh_transport_resolution() {
    local expected_user="$CBDB_USER"
    [[ "$(id -u)" == "0" ]] && expected_user="root"
    local record host ip port role proxy_jump output actual_host actual_port actual_user
    for record in "${HOSTS[@]}"; do
        IFS='|' read -r host ip port role proxy_jump <<< "$record"
        output="$("${SSH_WRAPPER_DIR}/ssh" -G "$host" 2>>"$LOG_FILE")" || {
            log_error "Unable to resolve generated SSH alias: ${host}"
            return 1
        }
        actual_host="$(awk '$1 == "hostname" {print $2; exit}' <<< "$output")"
        actual_port="$(awk '$1 == "port" {print $2; exit}' <<< "$output")"
        actual_user="$(awk '$1 == "user" {print $2; exit}' <<< "$output")"
        if [[ "$actual_host" != "$ip" || "$actual_port" != "$port" || "$actual_user" != "$expected_user" ]]; then
            log_error "SSH alias mismatch for ${host}: expected=${expected_user}@${ip}:${port}, actual=${actual_user}@${actual_host}:${actual_port}"
            return 1
        fi
    done
    log_success "Generated SSH aliases resolve to the configured endpoints"
}

save_config() {
    local state="${1:-$INSTALL_STATE}"
    local temp_file
    temp_file="$(mktemp "${CONF_DIR}/install.conf.tmp.XXXXXX")" || return 1
    chmod 600 "$temp_file"

    {
        printf 'config_version=%s\n' "$CONFIG_VERSION"
        printf 'install_state=%s\n' "$state"
        printf 'install_mode=%s\n' "$INSTALL_MODE"
        printf 'cbdb_user=%s\n' "$CBDB_USER"
        printf 'cbdb_home=%s\n' "$CBDB_HOME"
        printf 'data_home=%s\n' "$CBDB_DATA_HOME"
        printf 'coordinator_host=%s\n' "$COORDINATOR_HOST"
        printf 'coordinator_port=%s\n' "$COORDINATOR_PORT"
        printf 'coordinator_directory=%s\n' "$COORDINATOR_DIRECTORY"
        printf 'coordinator_data_directory=%s\n' "$COORDINATOR_DATA_DIRECTORY"
        printf 'standby_enabled=%s\n' "$STANDBY_ENABLED"
        printf 'standby_host=%s\n' "$STANDBY_HOST"
        printf 'standby_data_directory=%s\n' "$STANDBY_DATA_DIRECTORY"
        printf 'segment_port_base=%s\n' "$SEGMENT_PORT_BASE"
        printf 'segment_data_directory=%s\n' "$SEGMENT_DATA_DIRECTORY"
        printf 'mirror_enabled=%s\n' "$MIRROR_ENABLED"
        printf 'mirror_mode=%s\n' "$MIRROR_MODE"
        printf 'mirror_port_base=%s\n' "$MIRROR_PORT_BASE"
        printf 'mirror_data_directory=%s\n' "$MIRROR_DATA_DIRECTORY"
        printf 'segments_per_host=%s\n' "$SEGMENTS_PER_HOST"
        printf 'database_name=%s\n' "$DATABASE_NAME"
        printf 'seg_prefix=%s\n' "$SEG_PREFIX"
        printf 'hosts=%s\n' "$(serialize_array ';' "${HOSTS[@]}")"
        printf 'segment_hosts=%s\n' "$(serialize_array ',' "${SEGMENT_HOSTS[@]}")"
        printf 'gpinitsystem_input=%s\n' "$GPINIT_INPUT"
    } > "$temp_file"

    if ! mv -f -- "$temp_file" "$INSTALL_CONF"; then
        rm -f -- "$temp_file"
        return 1
    fi
    INSTALL_STATE="$state"
    log_success "配置已保存: ${INSTALL_CONF} (${state})"
}

generate_cluster_env_file() {
    local product_env="${CBDB_HOME}/cloudberry-env.sh"
    if [[ ! -r "$product_env" ]]; then
        log_error "Cloudberry product environment file is not readable: ${product_env}"
        return 1
    fi

    local temp_file
    temp_file="$(mktemp "${CONF_DIR}/cluster-env.sh.tmp.XXXXXX")" || return 1
    chmod 600 "$temp_file" || {
        rm -f -- "$temp_file"
        return 1
    }

    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by cloudberry_tool.sh. Source this file; do not execute it.\n'
        printf 'source %q\n' "$product_env"
        printf 'export COORDINATOR_DATA_DIRECTORY=%q\n' "$COORDINATOR_DATA_DIRECTORY"
        printf 'export PGPORT=%q\n' "$COORDINATOR_PORT"
        printf 'export PGDATABASE=%q\n' "$DATABASE_NAME"
        printf 'export CLOUDBERRY_SSH_CONFIG=%q\n' "$SSH_CONFIG"
        printf 'export PATH=%q:"${PATH}"\n' "$SSH_WRAPPER_DIR"
    } > "$temp_file"

    if ! mv -f -- "$temp_file" "$CLUSTER_ENV_FILE"; then
        rm -f -- "$temp_file"
        return 1
    fi
    chmod 600 "$CLUSTER_ENV_FILE" || return 1
    log_success "Cluster environment file generated: ${CLUSTER_ENV_FILE}"
}

print_cluster_env_usage() {
    local source_command
    printf -v source_command 'source %q' "$CLUSTER_ENV_FILE"
    printf '\nActivate this cluster environment in the current shell:\n  %s\n\n' "$source_command"
}

remove_cluster_env_file() {
    if [[ ! -e "$CLUSTER_ENV_FILE" && ! -L "$CLUSTER_ENV_FILE" ]]; then
        return 0
    fi
    if ! rm -f -- "$CLUSTER_ENV_FILE"; then
        log_warn "Unable to remove stale cluster environment file: ${CLUSTER_ENV_FILE}"
        return 1
    fi
    log_success "Removed cluster environment file: ${CLUSTER_ENV_FILE}"
}

load_config() {
    [[ -f "$INSTALL_CONF" ]] || { log_error "配置文件不存在: ${INSTALL_CONF}"; return 1; }
    reset_host_model
    local key value hosts_value="" segment_hosts_value="" required_key
    declare -A loaded_keys=()
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -n "$key" && "$key" != \#* ]] && loaded_keys["$key"]=1
        case "$key" in
            config_version) CONFIG_VERSION="$value" ;;
            install_state) INSTALL_STATE="$value" ;;
            install_mode) INSTALL_MODE="$value" ;;
            cbdb_user) CBDB_USER="$value" ;;
            cbdb_home) CBDB_HOME="$value" ;;
            data_home) CBDB_DATA_HOME="$value" ;;
            coordinator_host) COORDINATOR_HOST="$value" ;;
            coordinator_port) COORDINATOR_PORT="$value" ;;
            coordinator_directory) COORDINATOR_DIRECTORY="$value" ;;
            coordinator_data_directory) COORDINATOR_DATA_DIRECTORY="$value" ;;
            standby_enabled) STANDBY_ENABLED="$value" ;;
            standby_host) STANDBY_HOST="$value" ;;
            standby_data_directory) STANDBY_DATA_DIRECTORY="$value" ;;
            segment_port_base) SEGMENT_PORT_BASE="$value" ;;
            segment_data_directory) SEGMENT_DATA_DIRECTORY="$value" ;;
            mirror_enabled) MIRROR_ENABLED="$value" ;;
            mirror_mode) MIRROR_MODE="$value" ;;
            mirror_port_base) MIRROR_PORT_BASE="$value" ;;
            mirror_data_directory) MIRROR_DATA_DIRECTORY="$value" ;;
            segments_per_host) SEGMENTS_PER_HOST="$value" ;;
            database_name) DATABASE_NAME="$value" ;;
            seg_prefix) SEG_PREFIX="$value" ;;
            hosts) hosts_value="$value" ;;
            segment_hosts) segment_hosts_value="$value" ;;
            gpinitsystem_input) GPINIT_INPUT="$value" ;;
            ""|'#'*) ;;
            *) log_error "配置包含未知键: ${key}"; return 1 ;;
        esac
    done < "$INSTALL_CONF"

    local -a required_keys=(
        config_version install_state install_mode cbdb_user cbdb_home data_home
        coordinator_host coordinator_port coordinator_directory coordinator_data_directory
        standby_enabled standby_host standby_data_directory segment_port_base
        segment_data_directory mirror_enabled mirror_mode mirror_port_base
        mirror_data_directory segments_per_host database_name seg_prefix hosts
        segment_hosts gpinitsystem_input
    )
    for required_key in "${required_keys[@]}"; do
        [[ -n "${loaded_keys[$required_key]:-}" ]] || {
            log_error "配置缺少必需键: ${required_key}"
            return 1
        }
    done

    [[ "$CONFIG_VERSION" == "1" || "$CONFIG_VERSION" == "2" ]] || {
        log_error "不支持的配置版本: ${CONFIG_VERSION}"
        return 1
    }
    local -a loaded_hosts=()
    local record host ip port role proxy_jump
    IFS=';' read -r -a loaded_hosts <<< "$hosts_value"
    for record in "${loaded_hosts[@]}"; do
        [[ -n "$record" ]] || continue
        IFS='|' read -r host ip port role proxy_jump <<< "$record"
        add_host "$host" "$ip" "$port" "$role" "$proxy_jump" || return 1
    done
    # Version 1 host records had four fields and are upgraded in memory with
    # an empty ProxyJump. The next save writes the version 2 representation.
    CONFIG_VERSION=2
    IFS=',' read -r -a SEGMENT_HOSTS <<< "$segment_hosts_value"
    validate_loaded_config || return 1
    COORDINATOR_IP="${HOST_IP[$COORDINATOR_HOST]:-}"
    [[ -n "$COORDINATOR_IP" ]] || { log_error "Coordinator 不在 hosts 配置中"; return 1; }
    generate_ssh_transport_files || return 1
    validate_ssh_transport_resolution || return 1
}

validate_loaded_config() {
    validate_username "$CBDB_USER" || return 1
    [[ "$SEG_PREFIX" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 1
    validate_hostname "$COORDINATOR_HOST" || return 1
    host_exists "$COORDINATOR_HOST" || return 1
    validate_port "$COORDINATOR_PORT" || return 1
    validate_port "$SEGMENT_PORT_BASE" || return 1
    validate_install_path "$CBDB_HOME" || return 1
    validate_data_root "$CBDB_DATA_HOME" || return 1
    validate_path "$COORDINATOR_DIRECTORY" || return 1
    validate_path "$COORDINATOR_DATA_DIRECTORY" || return 1
    validate_path "$SEGMENT_DATA_DIRECTORY" || return 1
    validate_database_name "$DATABASE_NAME" || return 1
    [[ "$INSTALL_STATE" =~ ^(planned|ready|installed|failed|uninstalled)$ ]] || return 1
    [[ "$INSTALL_MODE" =~ ^(demo|fast|custom|check)$ ]] || return 1
    [[ "$SEGMENTS_PER_HOST" =~ ^[0-9]+$ ]] && (( SEGMENTS_PER_HOST >= 1 && SEGMENTS_PER_HOST <= 128 )) || return 1
    [[ "$GPINIT_INPUT" == "${CONF_DIR}/gpinitsystem_input" ]] || return 1
    is_path_within "$COORDINATOR_DIRECTORY" "$CBDB_DATA_HOME" || return 1
    is_path_within "$SEGMENT_DATA_DIRECTORY" "$CBDB_DATA_HOME" || return 1
    [[ "$COORDINATOR_DATA_DIRECTORY" == "${COORDINATOR_DIRECTORY}/${SEG_PREFIX}-1" ]] || return 1
    local segment_host
    for segment_host in "${SEGMENT_HOSTS[@]}"; do
        validate_hostname "$segment_host" || return 1
        host_exists "$segment_host" || return 1
    done
    (( ${#SEGMENT_HOSTS[@]} > 0 )) || return 1
    [[ "$MIRROR_ENABLED" == "true" || "$MIRROR_ENABLED" == "false" ]] || return 1
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        validate_path "$MIRROR_DATA_DIRECTORY" || return 1
        validate_port "$MIRROR_PORT_BASE" || return 1
        [[ "$MIRROR_MODE" == "group" || "$MIRROR_MODE" == "spread" ]] || return 1
        is_path_within "$MIRROR_DATA_DIRECTORY" "$CBDB_DATA_HOME" || return 1
    fi
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        validate_hostname "$STANDBY_HOST" || return 1
        host_exists "$STANDBY_HOST" || return 1
        validate_path "$STANDBY_DATA_DIRECTORY" || return 1
        is_path_within "$STANDBY_DATA_DIRECTORY" "$CBDB_DATA_HOME" || return 1
    fi
    validate_port_ranges
}

###############################################################################
# Configuration input and intended topology
###############################################################################

input_base_config() {
    local demo_mode="${1:-false}"
    prompt_validated_string "Cloudberry OS user" "$CBDB_USER" validate_username \
        "用户名称格式无效" || return 1
    CBDB_USER="$READ_VALUE"

    prompt_validated_string "Cloudberry installation path" "$CBDB_HOME" validate_install_path \
        "安装路径必须是安全的绝对路径" || return 1
    CBDB_HOME="$(canonicalize_path "$READ_VALUE")"

    if [[ "$demo_mode" == "true" ]]; then
        CBDB_DATA_HOME="${HOME}/cloudberry-data/demo"
    fi
    prompt_validated_string "Cloudberry data root" "$CBDB_DATA_HOME" validate_data_root \
        "数据根目录必须是安全的绝对路径" || return 1
    CBDB_DATA_HOME="$(canonicalize_path "$READ_VALUE")"

    read_int "Coordinator port" "$COORDINATOR_PORT" 1024 65535 || return 1
    COORDINATOR_PORT="$READ_VALUE"
    read_int "Primary segment port base" "$SEGMENT_PORT_BASE" 1024 65535 || return 1
    SEGMENT_PORT_BASE="$READ_VALUE"
    read_int "Primary segments per host" "$SEGMENTS_PER_HOST" 1 128 || return 1
    SEGMENTS_PER_HOST="$READ_VALUE"

    prompt_validated_string "Database name" "$DATABASE_NAME" validate_database_name \
        "数据库名格式无效" || return 1
    DATABASE_NAME="$READ_VALUE"

    COORDINATOR_DIRECTORY="${CBDB_DATA_HOME}/coordinator"
    COORDINATOR_DATA_DIRECTORY="${COORDINATOR_DIRECTORY}/${SEG_PREFIX}-1"
    SEGMENT_DATA_DIRECTORY="${CBDB_DATA_HOME}/primary"
    MIRROR_DATA_DIRECTORY="${CBDB_DATA_HOME}/mirror"

    if confirm "Enable mirror segments?" "N"; then
        MIRROR_ENABLED="true"
        read_int "Mirror segment port base" "$MIRROR_PORT_BASE" 1024 65535 || return 1
        MIRROR_PORT_BASE="$READ_VALUE"
    else
        MIRROR_ENABLED="false"
    fi

    validate_port_ranges
}

prompt_cluster_data_path() {
    local prompt="$1"
    local default_value="$2"
    while true; do
        prompt_validated_string "$prompt" "$default_value" validate_path \
            "数据目录必须是安全的绝对路径" || return 1
        if is_path_within "$READ_VALUE" "$CBDB_DATA_HOME"; then
            READ_VALUE="$(canonicalize_path "$READ_VALUE")"
            return 0
        fi
        log_error "数据目录必须位于 ${CBDB_DATA_HOME} 下"
    done
}

validate_port_ranges() {
    local primary_end=$((SEGMENT_PORT_BASE + SEGMENTS_PER_HOST - 1))
    (( primary_end <= 65535 )) || { log_error "Primary segment 端口范围超过 65535"; return 1; }
    if (( COORDINATOR_PORT >= SEGMENT_PORT_BASE && COORDINATOR_PORT <= primary_end )); then
        log_error "Coordinator 端口与 Primary segment 端口范围重叠"
        return 1
    fi
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        local mirror_end=$((MIRROR_PORT_BASE + SEGMENTS_PER_HOST - 1))
        (( mirror_end <= 65535 )) || { log_error "Mirror segment 端口范围超过 65535"; return 1; }
        if (( COORDINATOR_PORT >= MIRROR_PORT_BASE && COORDINATOR_PORT <= mirror_end )); then
            log_error "Coordinator 端口与 Mirror segment 端口范围重叠"
            return 1
        fi
        if (( SEGMENT_PORT_BASE <= mirror_end && MIRROR_PORT_BASE <= primary_end )); then
            log_error "Primary 与 Mirror segment 端口范围重叠"
            return 1
        fi
    fi
}

generate_demo_topology() {
    reset_host_model
    INSTALL_MODE="demo"
    local local_hostname local_ip ssh_port proxy_jump
    local_hostname="$(hostname)"
    local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    validate_ip "$local_ip" || local_ip="127.0.0.1"

    SEGMENTS_PER_HOST=3
    input_base_config "true" || return 1
    read_int "Local SSH port" 22 1 65535 || return 1
    ssh_port="$READ_VALUE"
    while true; do
        read_string "Local ProxyJump ([user@]host[:port], comma-separated; blank for none)" "" || return 1
        proxy_jump="$READ_VALUE"
        validate_proxy_jump "$proxy_jump" && break
        log_error "ProxyJump 格式无效"
    done
    add_host "$local_hostname" "$local_ip" "$ssh_port" "coordinator,segment" "$proxy_jump" || return 1
    COORDINATOR_HOST="$local_hostname"
    COORDINATOR_IP="$local_ip"
    SEGMENT_HOSTS=("$local_hostname")

    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        log_warn "Demo Mirror 与 Primary 位于同一物理主机，仅用于功能测试，不提供主机级高可用"
        confirm "I understand and want to keep Demo mirrors" "N" || MIRROR_ENABLED="false"
    fi
}

generate_fast_topology() {
    reset_host_model
    INSTALL_MODE="fast"
    input_base_config "false" || return 1

    local host_count
    read_int "Total host count (first host is Coordinator)" 4 2 256 || return 1
    host_count="$READ_VALUE"
    input_hosts "$host_count" "coordinator-first" || return 1

    if [[ "$MIRROR_ENABLED" == "true" && ${#SEGMENT_HOSTS[@]} -lt 2 ]]; then
        log_warn "只有一台 Segment Host，无法保证 Primary 与 Mirror 跨主机部署；已关闭 Mirror"
        MIRROR_ENABLED="false"
    fi
    MIRROR_MODE="group"
}

generate_custom_topology() {
    reset_host_model
    INSTALL_MODE="custom"
    input_base_config "false" || return 1

    prompt_cluster_data_path "Coordinator directory root" "$COORDINATOR_DIRECTORY" || return 1
    COORDINATOR_DIRECTORY="$READ_VALUE"
    COORDINATOR_DATA_DIRECTORY="${COORDINATOR_DIRECTORY}/${SEG_PREFIX}-1"
    prompt_cluster_data_path "Primary segment directory root" "$SEGMENT_DATA_DIRECTORY" || return 1
    SEGMENT_DATA_DIRECTORY="$READ_VALUE"
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        prompt_cluster_data_path "Mirror segment directory root" "$MIRROR_DATA_DIRECTORY" || return 1
        MIRROR_DATA_DIRECTORY="$READ_VALUE"
    fi

    local host_count host coordinator_choice selection
    read_int "Host count" 4 2 256 || return 1
    host_count="$READ_VALUE"
    input_hosts "$host_count" "pool" || return 1

    printf '\nAvailable hosts:\n'
    for host in "${HOSTS[@]}"; do
        printf '  %s\n' "${host%%|*}"
    done
    while true; do
        read_string "Coordinator host" "" || return 1
        coordinator_choice="$READ_VALUE"
        host_exists "$coordinator_choice" && break
        log_error "未知 Coordinator Host: ${coordinator_choice}"
    done
    COORDINATOR_HOST="$coordinator_choice"
    COORDINATOR_IP="${HOST_IP[$COORDINATOR_HOST]}"
    HOST_ROLE["$COORDINATOR_HOST"]="coordinator"

    while true; do
        read_string "Segment hosts (comma separated)" "" || return 1
        selection="$READ_VALUE"
        parse_host_selection "$selection" "false" || continue
        local contains_coordinator="false"
        for host in "${SEGMENT_HOSTS[@]}"; do
            [[ "$host" == "$COORDINATOR_HOST" ]] && contains_coordinator="true"
        done
        if [[ "$contains_coordinator" == "true" ]]; then
            log_error "自定义多机模式不允许 Coordinator 同时作为 Segment Host"
            continue
        fi
        break
    done
    for host in "${SEGMENT_HOSTS[@]}"; do
        HOST_ROLE["$host"]="segment"
    done

    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        if [[ ${#SEGMENT_HOSTS[@]} -lt 2 ]]; then
            log_warn "少于两台 Segment Host，已关闭 Mirror"
            MIRROR_ENABLED="false"
        else
            while true; do
                read_string "Mirror mode (group/spread)" "group" || return 1
                case "$READ_VALUE" in
                    group)
                        MIRROR_MODE="group"
                        break
                        ;;
                    spread)
                        if (( ${#SEGMENT_HOSTS[@]} <= SEGMENTS_PER_HOST )); then
                            log_error "Spread Mirror requires Segment host count to be greater than Primary segments per host"
                            log_error "Current topology: hosts=${#SEGMENT_HOSTS[@]}, Primary/host=${SEGMENTS_PER_HOST}"
                            log_info "Choose group, add Segment hosts, or reduce Primary segments per host"
                            continue
                        fi
                        MIRROR_MODE="spread"
                        break
                        ;;
                    *)
                        log_error "Mirror mode 只能是 group 或 spread"
                        ;;
                esac
            done
        fi
    fi

    if confirm "Configure a Standby Coordinator?" "N"; then
        while true; do
            read_string "Standby Coordinator host" "" || return 1
            STANDBY_HOST="$READ_VALUE"
            if ! host_exists "$STANDBY_HOST"; then
                log_error "未知 Standby Host"
            elif [[ "$STANDBY_HOST" == "$COORDINATOR_HOST" ]]; then
                log_error "Standby 不得与 Coordinator 相同"
            elif printf '%s\n' "${SEGMENT_HOSTS[@]}" | grep -Fxq -- "$STANDBY_HOST"; then
                log_error "MVP 不允许 Standby 与 Segment 混部"
            else
                break
            fi
        done
        STANDBY_ENABLED="true"
        HOST_ROLE["$STANDBY_HOST"]="standby"
        STANDBY_DATA_DIRECTORY="${CBDB_DATA_HOME}/standby/${SEG_PREFIX}-1"
        prompt_cluster_data_path "Standby Coordinator data directory" "$STANDBY_DATA_DIRECTORY" || return 1
        STANDBY_DATA_DIRECTORY="$READ_VALUE"
    fi

    filter_configured_hosts
    rebuild_host_records
}

filter_configured_hosts() {
    local -a filtered=()
    local record host keep segment_host
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        keep="false"
        [[ "$host" == "$COORDINATOR_HOST" ]] && keep="true"
        [[ "$STANDBY_ENABLED" == "true" && "$host" == "$STANDBY_HOST" ]] && keep="true"
        for segment_host in "${SEGMENT_HOSTS[@]}"; do
            [[ "$host" == "$segment_host" ]] && keep="true"
        done
        [[ "$keep" == "true" ]] && filtered+=("$record")
    done
    HOSTS=("${filtered[@]}")
}

rebuild_host_records() {
    local -a rebuilt=()
    local record host ip port role proxy_jump
    for record in "${HOSTS[@]}"; do
        IFS='|' read -r host ip port role proxy_jump <<< "$record"
        rebuilt+=("${host}|${ip}|${port}|${HOST_ROLE[$host]}|${proxy_jump}")
    done
    HOSTS=("${rebuilt[@]}")
}

print_intended_topology() {
    local primary_end=$((SEGMENT_PORT_BASE + SEGMENTS_PER_HOST - 1))
    printf '\n================================================\n'
    printf 'Cloudberry Intended Cluster Configuration\n'
    printf '================================================\n\n'
    printf 'Mode                 : %s\n' "$INSTALL_MODE"
    printf 'Cloudberry user      : %s\n' "$CBDB_USER"
    printf 'Cloudberry home      : %s\n' "$CBDB_HOME"
    printf 'Coordinator          : %s (%s)\n' "$COORDINATOR_HOST" "$COORDINATOR_IP"
    printf 'Coordinator port     : %s\n' "$COORDINATOR_PORT"
    printf 'Coordinator data     : %s\n' "$COORDINATOR_DATA_DIRECTORY"
    printf 'Segment hosts        : %s\n' "$(serialize_array ',' "${SEGMENT_HOSTS[@]}")"
    printf 'Primary/host         : %s\n' "$SEGMENTS_PER_HOST"
    printf 'Primary port range   : %s-%s on each host\n' "$SEGMENT_PORT_BASE" "$primary_end"
    printf 'Primary data root    : %s\n' "$SEGMENT_DATA_DIRECTORY"
    printf 'Mirror enabled       : %s\n' "$MIRROR_ENABLED"
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        printf 'Mirror mode          : %s\n' "$MIRROR_MODE"
        printf 'Mirror port range    : %s-%s on each host\n' \
            "$MIRROR_PORT_BASE" "$((MIRROR_PORT_BASE + SEGMENTS_PER_HOST - 1))"
        printf 'Mirror data root     : %s\n' "$MIRROR_DATA_DIRECTORY"
    fi
    printf 'Standby enabled      : %s\n' "$STANDBY_ENABLED"
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        printf 'Standby host         : %s\n' "$STANDBY_HOST"
        printf 'Standby data         : %s\n' "$STANDBY_DATA_DIRECTORY"
    fi
    printf 'Database             : %s\n' "$DATABASE_NAME"
    printf '\nSSH endpoints\n--------------------------------\n'
    local record host ip port role proxy_jump
    for record in "${HOSTS[@]}"; do
        IFS='|' read -r host ip port role proxy_jump <<< "$record"
        printf '%-18s %s@%s:%s' "$host" "$CBDB_USER" "$ip" "$port"
        [[ -n "$proxy_jump" ]] && printf ' via %s' "$proxy_jump"
        printf '\n'
    done
    printf '\nFinal content IDs and Mirror placement are resolved by gpinitsystem -O.\n'
}

###############################################################################
# Generated files
###############################################################################

write_atomic_file() {
    local target="$1"
    local content="$2"
    local temp_file
    temp_file="$(mktemp "${target}.tmp.XXXXXX")" || return 1
    chmod 600 "$temp_file"
    printf '%s' "$content" > "$temp_file"
    mv -f -- "$temp_file" "$target"
}

generate_hostfile() {
    local all_content="" segment_content="" record host
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        all_content+="${host}"$'\n'
    done
    for host in "${SEGMENT_HOSTS[@]}"; do
        segment_content+="${host}"$'\n'
    done
    write_atomic_file "$HOSTFILE" "$all_content" || return 1
    write_atomic_file "$GPINIT_HOSTFILE" "$segment_content" || return 1
    log_success "已生成 hostfile: ${HOSTFILE}"
    log_success "已生成 gpinitsystem hostfile: ${GPINIT_HOSTFILE}"
}

generate_gpinitsystem_config() {
    local primary_dirs="" mirror_dirs="" index
    for ((index = 0; index < SEGMENTS_PER_HOST; index++)); do
        primary_dirs+="${primary_dirs:+ }${SEGMENT_DATA_DIRECTORY}"
        mirror_dirs+="${mirror_dirs:+ }${MIRROR_DATA_DIRECTORY}"
    done

    local content
    content="# Generated by cloudberry_tool.sh. Do not edit during installation.\n"
    content+="SEG_PREFIX=${SEG_PREFIX}\n"
    content+="PORT_BASE=${SEGMENT_PORT_BASE}\n"
    content+="declare -a DATA_DIRECTORY=(${primary_dirs})\n"
    content+="COORDINATOR_HOSTNAME=${COORDINATOR_HOST}\n"
    content+="COORDINATOR_DIRECTORY=${COORDINATOR_DIRECTORY}\n"
    content+="COORDINATOR_PORT=${COORDINATOR_PORT}\n"
    content+="TRUSTED_SHELL=ssh\n"
    content+="ENCODING=UNICODE\n"
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        content+="MIRROR_PORT_BASE=${MIRROR_PORT_BASE}\n"
        content+="declare -a MIRROR_DATA_DIRECTORY=(${mirror_dirs})\n"
    fi
    write_atomic_file "$GPINIT_CONFIG" "$(printf '%b' "$content")"$'\n' || return 1
    log_success "已生成 gpinitsystem 配置: ${GPINIT_CONFIG}"
}

###############################################################################
# Environment and safety checks
###############################################################################

check_current_user() {
    local current_user
    current_user="$(id -un)"
    if [[ "$current_user" == "root" ]]; then
        log_error "root 可以执行环境准备，但不能运行 Cloudberry 初始化；请切换到 ${CBDB_USER}"
        return 1
    fi
    if [[ "$current_user" != "$CBDB_USER" ]]; then
        log_error "当前用户是 ${current_user}，安装和运维必须由 ${CBDB_USER} 执行"
        return 1
    fi
    log_success "Current user: ${current_user}"
}

check_coordinator_is_local() {
    local local_hostname
    local_hostname="$(hostname)"
    if [[ "$local_hostname" != "$COORDINATOR_HOST" ]]; then
        log_error "gpinitsystem 必须在 Coordinator 主机运行"
        log_error "当前 hostname=${local_hostname}, configured Coordinator=${COORDINATOR_HOST}"
        return 1
    fi
    log_success "Coordinator execution host verified: ${local_hostname}"
}

prepare_gpadmin_user() {
    check_current_user || return 1
    local record host
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        if ! run_remote "$host" id -u "$CBDB_USER" >/dev/null; then
            log_error "Required OS user does not exist on ${host}: ${CBDB_USER}"
            log_error "Create the same non-root user on all hosts, then rerun this operation"
            return 1
        fi
    done
    log_success "Cloudberry OS user exists on all configured hosts: ${CBDB_USER}"
}

check_dependencies() {
    local -a base_commands=(bash ssh scp ssh-keyscan rsync tar awk sed grep hostname ip df getconf sort mktemp find dirname)
    local -a gp_commands=(postgres gpinitsystem gpinitstandby gpstart gpstop gpstate gpssh gpssh-exkeys gpdeletesystem createdb psql)
    local command_name missing=0
    for command_name in "${base_commands[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log_error "Missing dependency: ${command_name}"
            missing=1
        fi
    done
    for command_name in "${gp_commands[@]}"; do
        if [[ ! -x "${CBDB_HOME}/bin/${command_name}" ]]; then
            log_error "Missing Cloudberry tool: ${CBDB_HOME}/bin/${command_name}"
            missing=1
        fi
    done
    (( missing == 0 ))
}

check_local_dependencies_for_dry_run() {
    local command_name
    for command_name in bash awk grep hostname mktemp sort; do
        command -v "$command_name" >/dev/null 2>&1 || {
            log_error "Missing local dependency: ${command_name}"
            return 1
        }
    done
}

check_ssh() {
    local record host remote_hostname remote_user addresses expected_ip
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        expected_ip="${HOST_IP[$host]}"
        log_info "Checking SSH connectivity: ${host}"
        if ! remote_hostname="$(capture_remote "$host" hostname)"; then
            log_error "SSH unreachable without a password: ${host}"
            return 1
        fi
        remote_hostname="$(trim "$remote_hostname")"
        if [[ "$remote_hostname" != "$host" ]]; then
            log_error "Hostname mismatch: configured=${host}, remote=${remote_hostname}"
            return 1
        fi
        if ! remote_user="$(capture_remote "$host" id -un)"; then
            log_error "Cannot determine remote user: ${host}"
            return 1
        fi
        remote_user="$(trim "$remote_user")"
        if [[ "$remote_user" != "$CBDB_USER" ]]; then
            log_error "Remote user mismatch on ${host}: expected=${CBDB_USER}, actual=${remote_user}"
            return 1
        fi
        addresses="$(capture_remote "$host" hostname -I 2>/dev/null || true)"
        if [[ " ${addresses} " != *" ${expected_ip} "* ]]; then
            log_warn "SSH endpoint ${expected_ip} is not a remote interface address on ${host}; accepting verified hostname (NAT/ProxyJump may be in use)"
        fi
        log_success "SSH and host identity verified: ${host}"
    done
}

prepare_ssh_keys() {
    if check_ssh; then
        return 0
    fi
    log_warn "Cloudberry requires password-free SSH between all hosts"
    local record host ip port role proxy_jump
    for record in "${HOSTS[@]}"; do
        IFS='|' read -r host ip port role proxy_jump <<< "$record"
        if [[ -n "$proxy_jump" ]]; then
            log_error "gpssh-exkeys cannot bootstrap ${host} through ProxyJump=${proxy_jump}"
            log_error "Configure key-based SSH through the jump host first, then rerun the check"
            return 1
        fi
    done
    if ! confirm "Run gpssh-exkeys using ${HOSTFILE}? It may prompt for passwords" "N"; then
        return 1
    fi
    run_gp_command "${CBDB_HOME}/bin/gpssh-exkeys" -f "$HOSTFILE" || return 1
    check_ssh
}

check_gp_ssh_transport() {
    log_info "Validating SSH aliases through the official gpssh utility"
    local gp_path="${SSH_WRAPPER_DIR}:${CBDB_HOME}/bin:${PATH}"
    local gp_lib="${CBDB_HOME}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    local gp_python="${CBDB_HOME}/lib/python${PYTHONPATH:+:${PYTHONPATH}}"
    local record host marker output status
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        marker="cloudberry-tool-gpssh-${host}"
        log_info "gpssh transport check: ${host}"
        output="$(env \
            "GPHOME=${CBDB_HOME}" \
            "COORDINATOR_DATA_DIRECTORY=${COORDINATOR_DATA_DIRECTORY}" \
            "USER=${CBDB_USER}" \
            "LOGNAME=${CBDB_USER}" \
            "PATH=${gp_path}" \
            "LD_LIBRARY_PATH=${gp_lib}" \
            "PYTHONPATH=${gp_python}" \
            "${CBDB_HOME}/bin/gpssh" -h "$host" "printf '%s\\n' '${marker}'" 2>&1)"
        status=$?
        [[ -n "$output" ]] && printf '%s\n' "$output" | tee -a "$LOG_FILE"
        if (( status != 0 )) || [[ "$output" == *"[ERROR]"* ]] || [[ "$output" != *"[${host}] ${marker}"* ]]; then
            log_error "gpssh did not return the expected marker from ${host}"
            return 1
        fi
    done
    log_success "Official gpssh transport validation passed"
}

check_remote_dependencies() {
    local record host
    local script='for c in bash ssh rsync tar awk sed grep hostname ip df getconf sort find dirname install; do command -v "$c" >/dev/null 2>&1 || { echo "missing:$c"; exit 1; }; done'
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        if ! run_remote "$host" bash -c "$script"; then
            log_error "Remote dependency check failed: ${host}"
            return 1
        fi
    done
}

check_resources() {
    local record host output
    local script='cpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown); mem=$(awk "/MemTotal:/ {printf \"%.1f GB\", \$2/1024/1024}" /proc/meminfo); path="$1"; while [ ! -e "$path" ] && [ "$path" != / ]; do path=$(dirname "$path"); done; disk=$(df -Pk "$path" 2>/dev/null | awk "NR==2 {printf \"%.1f GB\", \$4/1024/1024}"); printf "CPU=%s Memory=%s DiskAvailable=%s\n" "$cpu" "${mem:-unknown}" "${disk:-unknown}"'
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        output="$(capture_remote "$host" bash -c "$script" bash "$CBDB_DATA_HOME" 2>/dev/null || true)"
        if [[ -z "$output" ]]; then
            log_warn "Unable to collect resources from ${host}"
        else
            log_success "${host}: ${output}"
        fi
    done
}

check_port_on_host() {
    local host="$1"
    local port="$2"
    local script='port="$1"; if command -v ss >/dev/null 2>&1; then if ss -ltnH | awk "{print \$4}" | grep -Eq "[:.]${port}$"; then exit 1; fi; else if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then exec 3<&-; exec 3>&-; exit 1; fi; fi'
    if ! run_remote "$host" bash -c "$script" bash "$port"; then
        log_error "Port ${port} is already in use on ${host}"
        return 1
    fi
}

check_ports() {
    local host offset
    check_port_on_host "$COORDINATOR_HOST" "$COORDINATOR_PORT" || return 1
    for host in "${SEGMENT_HOSTS[@]}"; do
        for ((offset = 0; offset < SEGMENTS_PER_HOST; offset++)); do
            check_port_on_host "$host" "$((SEGMENT_PORT_BASE + offset))" || return 1
            if [[ "$MIRROR_ENABLED" == "true" ]]; then
                check_port_on_host "$host" "$((MIRROR_PORT_BASE + offset))" || return 1
            fi
        done
    done
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        check_port_on_host "$STANDBY_HOST" "$COORDINATOR_PORT" || return 1
    fi
    log_success "All planned ports are available"
}

check_path_has_no_database() {
    local host="$1"
    local root="$2"
    local pattern="$3"
    local script='root="$1"; pattern="$2"; if [ -e "$root" ] && [ ! -d "$root" ]; then exit 2; fi; if [ -d "$root" ] && find "$root" -mindepth 1 -maxdepth 1 -name "$pattern" -print -quit | grep -q .; then exit 3; fi'
    if ! run_remote "$host" bash -c "$script" bash "$root" "$pattern"; then
        log_error "Existing database-like path detected on ${host}: ${root}/${pattern}"
        return 1
    fi
}

check_directories() {
    local host
    check_path_has_no_database "$COORDINATOR_HOST" "$COORDINATOR_DIRECTORY" "${SEG_PREFIX}-1" || return 1
    for host in "${SEGMENT_HOSTS[@]}"; do
        check_path_has_no_database "$host" "$SEGMENT_DATA_DIRECTORY" "${SEG_PREFIX}*" || return 1
        if [[ "$MIRROR_ENABLED" == "true" ]]; then
            check_path_has_no_database "$host" "$MIRROR_DATA_DIRECTORY" "${SEG_PREFIX}*" || return 1
        fi
    done
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        check_path_has_no_database "$STANDBY_HOST" "$(dirname "$STANDBY_DATA_DIRECTORY")" "${SEG_PREFIX}-1" || return 1
    fi
    log_success "Target instance directories do not contain an existing cluster"
}

probe_port_state_on_host() {
    local host="$1"
    local port="$2"
    local script='port="$1"; state=stopped; if command -v ss >/dev/null 2>&1; then if ss -ltnH | awk "{print \$4}" | grep -Eq "[:.]${port}$"; then state=listening; fi; else if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then exec 3<&-; exec 3>&-; state=listening; fi; fi; printf "%s\n" "$state"'
    local output
    if ! output="$(capture_remote "$host" bash -c "$script" bash "$port")"; then
        log_error "Unable to inspect configured port on ${host}: ${port}"
        return 1
    fi
    case "$output" in
        listening|stopped) PORT_PROBE_STATE="$output" ;;
        *)
            log_error "Unexpected port probe result on ${host}:${port}: ${output}"
            return 1
            ;;
    esac
}

check_cluster_directory_on_host() {
    local host="$1"
    local path="$2"
    log_info "Checking configured cluster directory on ${host}: ${path}"
    if ! remote_test "$host" test -d "$path"; then
        log_error "Configured cluster directory is missing on ${host}: ${path}"
        return 1
    fi
}

check_installed_directories() {
    parse_gpinitsystem_input || return 1

    local record content dbid host address port data role
    for record in "$PARSED_COORDINATOR" "${PRIMARY_SEGMENTS[@]}" "${MIRROR_SEGMENTS[@]}"; do
        IFS='|' read -r content dbid host address port data role <<< "$record"
        check_cluster_directory_on_host "$host" "$data" || return 1
    done
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        check_cluster_directory_on_host "$STANDBY_HOST" "$STANDBY_DATA_DIRECTORY" || return 1
    fi
    log_success "All configured cluster instance directories are present"
}

inspect_cluster_runtime_state() {
    parse_gpinitsystem_input || return 1

    local record content dbid host address port data role
    local -a listening_instances=()
    local -a stopped_instances=()
    CLUSTER_RUNTIME_TOTAL=0
    CLUSTER_RUNTIME_LISTENING=0

    for record in "$PARSED_COORDINATOR" "${PRIMARY_SEGMENTS[@]}" "${MIRROR_SEGMENTS[@]}"; do
        IFS='|' read -r content dbid host address port data role <<< "$record"
        probe_port_state_on_host "$host" "$port" || return 1
        ((CLUSTER_RUNTIME_TOTAL++))
        if [[ "$PORT_PROBE_STATE" == "listening" ]]; then
            ((CLUSTER_RUNTIME_LISTENING++))
            listening_instances+=("${host}:${port}")
        else
            stopped_instances+=("${host}:${port}")
        fi
    done
    if (( CLUSTER_RUNTIME_LISTENING == 0 )); then
        CLUSTER_RUNTIME_STATE="STOPPED"
        log_success "Cluster state: STOPPED (0/${CLUSTER_RUNTIME_TOTAL} core instance ports listening)"
    elif (( CLUSTER_RUNTIME_LISTENING == CLUSTER_RUNTIME_TOTAL )); then
        CLUSTER_RUNTIME_STATE="RUNNING"
        log_success "Cluster process state: RUNNING (${CLUSTER_RUNTIME_LISTENING}/${CLUSTER_RUNTIME_TOTAL} core instance ports listening)"
    else
        CLUSTER_RUNTIME_STATE="PARTIALLY_RUNNING"
        log_error "Cluster state: PARTIALLY RUNNING (${CLUSTER_RUNTIME_LISTENING}/${CLUSTER_RUNTIME_TOTAL} core instance ports listening)"
        log_error "Listening instances: ${listening_instances[*]}"
        log_error "Stopped instances: ${stopped_instances[*]}"
    fi
}

prepare_directories() {
    local record host
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        run_remote "$host" install -d -m 700 "$LOG_DIR" || {
            log_error "Unable to prepare Cloudberry utility log directory on ${host}: ${LOG_DIR}"
            return 1
        }
    done
    log_success "Cloudberry utility log directory is ready on all configured hosts: ${LOG_DIR}"

    run_remote "$COORDINATOR_HOST" install -d -m 700 "$COORDINATOR_DIRECTORY" || return 1
    for host in "${SEGMENT_HOSTS[@]}"; do
        run_remote "$host" install -d -m 700 "$SEGMENT_DATA_DIRECTORY" || return 1
        if [[ "$MIRROR_ENABLED" == "true" ]]; then
            run_remote "$host" install -d -m 700 "$MIRROR_DATA_DIRECTORY" || return 1
        fi
    done
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        run_remote "$STANDBY_HOST" install -d -m 700 "$(dirname "$STANDBY_DATA_DIRECTORY")" || return 1
    fi
    log_success "Data directory parents are ready"
}

check_environment() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "MVP only supports Linux"
        return 1
    fi
    check_current_user || return 1
    check_coordinator_is_local || return 1
    check_dependencies || return 1
    prepare_hosts || return 1
    check_resources
    if [[ "$INSTALL_STATE" == "installed" ]]; then
        log_info "Environment check mode: installed cluster runtime"
        check_binary || return 1
        log_success "Cloudberry binary is present and consistent on all configured hosts"
        check_installed_directories || return 1
        inspect_cluster_runtime_state || return 1
        case "$CLUSTER_RUNTIME_STATE" in
            RUNNING)
                verify_standby_catalog || return 1
                run_gp_command "${CBDB_HOME}/bin/gpstate" -b -d "$COORDINATOR_DATA_DIRECTORY" || return 1
                log_success "Running-cluster environment check completed"
                return 0
                ;;
            STOPPED)
                log_success "Coordinator and all segment processes are stopped"
                log_success "Stopped-cluster environment check completed"
                return 0
                ;;
            PARTIALLY_RUNNING)
                log_error "Installed cluster runtime environment is inconsistent"
                return 1
                ;;
            *)
                log_error "Unable to classify installed cluster runtime state: ${CLUSTER_RUNTIME_STATE}"
                return 1
                ;;
        esac
    fi

    log_info "Environment check mode: pre-installation (${INSTALL_STATE})"
    check_ports || return 1
    check_directories || return 1
    log_success "Pre-installation environment check completed"
}

prepare_system_as_root() {
    [[ "$(id -u)" == "0" ]] || return 1
    log_warn "Root preparation mode: no Cloudberry database command will be executed"
    local record host remote_hostname remote_user
    local -a missing_users=()
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        if ! remote_hostname="$(capture_remote "$host" hostname)"; then
            log_error "Root SSH is not available on ${host}"
            return 1
        fi
        remote_hostname="$(trim "$remote_hostname")"
        [[ "$remote_hostname" == "$host" ]] || {
            log_error "Hostname mismatch: configured=${host}, remote=${remote_hostname}"
            return 1
        }
        remote_user="$(capture_remote "$host" id -un 2>/dev/null || true)"
        [[ "$(trim "$remote_user")" == "root" ]] || {
            log_error "Root preparation requires password-free root SSH on ${host}"
            return 1
        }
        if ! remote_test "$host" id -u "$CBDB_USER"; then
            missing_users+=("$host")
        fi
    done

    if (( ${#missing_users[@]} > 0 )); then
        log_warn "Missing ${CBDB_USER} user on: $(serialize_array ',' "${missing_users[@]}")"
        if ! confirm "Create ${CBDB_USER} with a home directory on these hosts?" "N"; then
            return 1
        fi
        for host in "${missing_users[@]}"; do
            run_remote "$host" useradd -m -U -s /bin/bash "$CBDB_USER" || return 1
        done
    fi

    if confirm "Prepare missing Cloudberry binary and data parent directories for ${CBDB_USER}?" "N"; then
        local path_script='user="$1"; shift; group=$(id -gn "$user") || exit 2; for path in "$@"; do if [ ! -e "$path" ]; then install -d -m 700 -o "$user" -g "$group" "$path" || exit 3; elif [ ! -d "$path" ]; then echo "not-directory:$path"; exit 4; fi; done'
        run_remote "$COORDINATOR_HOST" bash -c "$path_script" bash "$CBDB_USER" \
            "$COORDINATOR_DIRECTORY" || return 1
        for host in "${SEGMENT_HOSTS[@]}"; do
            if [[ "$MIRROR_ENABLED" == "true" ]]; then
                run_remote "$host" bash -c "$path_script" bash "$CBDB_USER" \
                    "$CBDB_HOME" "$SEGMENT_DATA_DIRECTORY" "$MIRROR_DATA_DIRECTORY" || return 1
            else
                run_remote "$host" bash -c "$path_script" bash "$CBDB_USER" \
                    "$CBDB_HOME" "$SEGMENT_DATA_DIRECTORY" || return 1
            fi
        done
        if [[ "$STANDBY_ENABLED" == "true" ]]; then
            run_remote "$STANDBY_HOST" bash -c "$path_script" bash "$CBDB_USER" \
                "$CBDB_HOME" "$(dirname "$STANDBY_DATA_DIRECTORY")" || return 1
        fi
    fi
    log_success "Root environment preparation completed"
    log_warn "Switch to ${CBDB_USER}, configure password-free SSH, then rerun cloudberry_tool.sh"
}

prepare_hosts() {
    prepare_ssh_keys || return 1
    prepare_gpadmin_user || return 1
    check_remote_dependencies || return 1
    check_gp_ssh_transport
}

###############################################################################
# Cloudberry binary check and distribution
###############################################################################

remote_binary_exists() {
    local host="$1"
    remote_test "$host" test -x "${CBDB_HOME}/bin/postgres" || return 1
    remote_test "$host" test -x "${CBDB_HOME}/bin/gpinitsystem"
}

local_binary_version() {
    local gp_lib="${CBDB_HOME}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    env "GPHOME=${CBDB_HOME}" "LD_LIBRARY_PATH=${gp_lib}" \
        "${CBDB_HOME}/bin/postgres" --gp-version 2>/dev/null || \
        env "GPHOME=${CBDB_HOME}" "LD_LIBRARY_PATH=${gp_lib}" \
        "${CBDB_HOME}/bin/postgres" --version 2>/dev/null
}

remote_binary_version() {
    local host="$1"
    local script='home="$1"; binary="${home}/bin/postgres"; export GPHOME="$home" LD_LIBRARY_PATH="${home}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"; "$binary" --gp-version 2>/dev/null || "$binary" --version 2>/dev/null'
    capture_remote "$host" bash -c "$script" bash "$CBDB_HOME"
}

check_binary() {
    [[ -x "${CBDB_HOME}/bin/postgres" && -x "${CBDB_HOME}/bin/gpinitsystem" ]] || {
        log_error "Coordinator 上未找到完整 Cloudberry binary: ${CBDB_HOME}"
        return 1
    }
    local expected_version record host actual_version missing=0
    expected_version="$(local_binary_version)" || return 1
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        if ! remote_binary_exists "$host" >/dev/null 2>&1; then
            log_warn "Cloudberry binary missing on ${host}"
            missing=1
            continue
        fi
        actual_version="$(remote_binary_version "$host")" || {
            log_error "Cannot read Cloudberry version on ${host}"
            return 1
        }
        if [[ "$actual_version" != "$expected_version" ]]; then
            log_error "Cloudberry version mismatch on ${host}"
            log_error "Expected: ${expected_version}; actual: ${actual_version}"
            return 1
        fi
    done
    (( missing == 0 ))
}

distribute_binary() {
    if check_binary; then
        log_success "Cloudberry binary is present and consistent on all hosts"
        return 0
    fi
    confirm "Distribute ${CBDB_HOME} from the Coordinator to missing hosts?" "N" || return 1

    local source_parent source_name archive archive_name record host remote_parent
    source_parent="$(dirname "$CBDB_HOME")"
    source_name="$(basename "$CBDB_HOME")"
    archive="$(mktemp "/tmp/cloudberry_binary.XXXXXX.tar")" || return 1
    archive_name="$(basename "$archive")"
    remote_parent="$source_parent"

    if ! run_command tar -C "$source_parent" -cpf "$archive" "$source_name"; then
        rm -f -- "$archive"
        return 1
    fi

    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        if remote_binary_exists "$host" >/dev/null 2>&1; then
            continue
        fi
        if remote_test "$host" test -e "$CBDB_HOME"; then
            local empty_script='path="$1"; [ -d "$path" ] && [ -w "$path" ] && ! find "$path" -mindepth 1 -print -quit | grep -q .'
            if ! remote_test "$host" bash -c "$empty_script" bash "$CBDB_HOME"; then
                log_error "Refusing to overwrite a non-empty or non-writable installation on ${host}: ${CBDB_HOME}"
                rm -f -- "$archive"
                return 1
            fi
        elif ! remote_test "$host" test -w "$remote_parent"; then
            log_error "Remote parent is not writable by ${CBDB_USER}: ${host}:${remote_parent}"
            rm -f -- "$archive"
            return 1
        fi
        if [[ -x "${CBDB_HOME}/bin/gpscp" ]]; then
            run_gp_command "${CBDB_HOME}/bin/gpscp" -h "$host" "$archive" "=:/tmp/${archive_name}" || {
                rm -f -- "$archive"
                return 1
            }
        else
            log_warn "gpscp is not available; falling back to scp for ${host}"
            run_command "${SSH_WRAPPER_DIR}/scp" -o BatchMode=yes -o ConnectTimeout=10 -- \
                "$archive" "${host}:/tmp/${archive_name}" || {
                rm -f -- "$archive"
                return 1
            }
        fi
        run_remote "$host" tar -C "$remote_parent" -xpf "/tmp/${archive_name}" || {
            rm -f -- "$archive"
            return 1
        }
        run_remote "$host" rm -f "/tmp/${archive_name}" || true
    done
    rm -f -- "$archive"
    check_binary
}

###############################################################################
# Official topology generation and parsing
###############################################################################

validate_resolved_record() {
    local record="$1"
    local expected_fields="$2"
    [[ "$record" != *'$('* && "$record" != *'`'* && "$record" != *';'* ]] || return 1
    local -a fields=()
    IFS='~' read -r -a fields <<< "$record"
    [[ ${#fields[@]} -eq "$expected_fields" ]] || return 1
    validate_hostname "${fields[0]}" || return 1
    validate_hostname "${fields[1]}" || return 1
    validate_port "${fields[2]}" || return 1
    validate_path "${fields[3]}" || return 1
    [[ "${fields[4]}" =~ ^[0-9]+$ ]] || return 1
    [[ "${fields[5]}" =~ ^-?[0-9]+$ ]] || return 1
}

append_resolved_record() {
    local record="$1"
    local role="$2"
    local -a fields=()
    IFS='~' read -r -a fields <<< "$record"
    # gpinitsystem SET_VAR defines field 1 as hostname and field 2 as the
    # address/name from hostfile_gpinitsystem.
    local host="${fields[0]}"
    local address="${fields[1]}"
    local port="${fields[2]}"
    local data_directory="${fields[3]}"
    local dbid="${fields[4]}"
    local content="${fields[5]}"
    local normalized="${content}|${dbid}|${host}|${address}|${port}|${data_directory}|${role}"
    case "$role" in
        Coordinator) PARSED_COORDINATOR="$normalized" ;;
        Primary) PRIMARY_SEGMENTS+=("$normalized") ;;
        Mirror) MIRROR_SEGMENTS+=("$normalized") ;;
    esac
}

parse_gpinitsystem_input() {
    [[ -s "$GPINIT_INPUT" ]] || { log_error "Official topology file is empty: ${GPINIT_INPUT}"; return 1; }
    PRIMARY_SEGMENTS=()
    MIRROR_SEGMENTS=()
    PARSED_COORDINATOR=""

    local line state="" record
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        case "$line" in
            TRUSTED_SHELL=ssh|HEAP_CHECKSUM=on|HEAP_CHECKSUM=off|HBA_HOSTNAMES=0|HBA_HOSTNAMES=1)
                ;;
            ENCODING=*)
                [[ "${line#ENCODING=}" =~ ^[A-Za-z0-9_-]+$ ]] || {
                    log_error "Invalid ENCODING in official topology"
                    return 1
                }
                ;;
            SEG_PREFIX=*)
                [[ "${line#SEG_PREFIX=}" == "$SEG_PREFIX" ]] || {
                    log_error "SEG_PREFIX changed in official topology"
                    return 1
                }
                ;;
            QD_PRIMARY_ARRAY=*)
                record="${line#QD_PRIMARY_ARRAY=}"
                validate_resolved_record "$record" 7 || {
                    log_error "Invalid QD_PRIMARY_ARRAY record"
                    return 1
                }
                append_resolved_record "$record" "Coordinator"
                ;;
            'declare -a PRIMARY_ARRAY=('|PRIMARY_ARRAY='(')
                [[ -z "$state" ]] || return 1
                state="primary"
                ;;
            'declare -a MIRROR_ARRAY=('|MIRROR_ARRAY='(')
                [[ -z "$state" ]] || return 1
                state="mirror"
                ;;
            ')')
                [[ -n "$state" ]] || { log_error "Unexpected array terminator"; return 1; }
                state=""
                ;;
            *)
                if [[ "$state" == "primary" || "$state" == "mirror" ]]; then
                    validate_resolved_record "$line" 6 || {
                        log_error "Invalid ${state} record in official topology"
                        return 1
                    }
                    if [[ "$state" == "primary" ]]; then
                        append_resolved_record "$line" "Primary"
                    else
                        append_resolved_record "$line" "Mirror"
                    fi
                else
                    log_error "Unsupported statement in official topology: ${line}"
                    return 1
                fi
                ;;
        esac
    done < "$GPINIT_INPUT"

    [[ -z "$state" ]] || { log_error "Unclosed array in official topology"; return 1; }
    [[ -n "$PARSED_COORDINATOR" ]] || { log_error "Missing Coordinator in official topology"; return 1; }
    local expected_primary=$(( ${#SEGMENT_HOSTS[@]} * SEGMENTS_PER_HOST ))
    [[ ${#PRIMARY_SEGMENTS[@]} -eq "$expected_primary" ]] || {
        log_error "Unexpected Primary count: expected=${expected_primary}, actual=${#PRIMARY_SEGMENTS[@]}"
        return 1
    }
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        [[ ${#MIRROR_SEGMENTS[@]} -eq ${#PRIMARY_SEGMENTS[@]} ]] || {
            log_error "Mirror count does not match Primary count"
            return 1
        }
    elif [[ ${#MIRROR_SEGMENTS[@]} -ne 0 ]]; then
        log_error "Official topology unexpectedly contains mirrors"
        return 1
    fi
    validate_resolved_topology
}

validate_resolved_topology() {
    local record content dbid host address port data role key
    declare -A content_primary=()
    declare -A content_mirror=()
    declare -A host_port=()
    declare -A dbid_seen=()
    for record in "$PARSED_COORDINATOR" "${PRIMARY_SEGMENTS[@]}" "${MIRROR_SEGMENTS[@]}"; do
        IFS='|' read -r content dbid host address port data role <<< "$record"
        host_exists "$host" || { log_error "Official topology contains unknown host: ${host}"; return 1; }
        validate_port "$port" || return 1
        validate_path "$data" || return 1
        key="${host}:${port}"
        [[ -z "${host_port[$key]:-}" ]] || { log_error "Duplicate host/port in official topology: ${key}"; return 1; }
        host_port["$key"]=1
        [[ -z "${dbid_seen[$dbid]:-}" ]] || { log_error "Duplicate dbid in official topology: ${dbid}"; return 1; }
        dbid_seen["$dbid"]=1
        case "$role" in
            Coordinator)
                [[ "$content" == "-1" && "$host" == "$COORDINATOR_HOST" ]] || return 1
                [[ "$data" == "$COORDINATOR_DATA_DIRECTORY" ]] || {
                    log_error "Unexpected Coordinator data directory: ${data}"
                    return 1
                }
                ;;
            Primary)
                [[ -z "${content_primary[$content]:-}" ]] || return 1
                array_contains "$host" "${SEGMENT_HOSTS[@]}" || {
                    log_error "Primary is placed on a non-Segment host: ${host}"
                    return 1
                }
                is_path_within "$data" "$SEGMENT_DATA_DIRECTORY" || {
                    log_error "Primary data directory is outside configured root: ${data}"
                    return 1
                }
                content_primary["$content"]="$host"
                ;;
            Mirror)
                [[ -z "${content_mirror[$content]:-}" ]] || return 1
                array_contains "$host" "${SEGMENT_HOSTS[@]}" || {
                    log_error "Mirror is placed on a non-Segment host: ${host}"
                    return 1
                }
                is_path_within "$data" "$MIRROR_DATA_DIRECTORY" || {
                    log_error "Mirror data directory is outside configured root: ${data}"
                    return 1
                }
                content_mirror["$content"]="$host"
                ;;
        esac
        [[ "$dbid" =~ ^[0-9]+$ && "$address" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    done
    if [[ "$MIRROR_ENABLED" == "true" && "$INSTALL_MODE" != "demo" ]]; then
        for content in "${!content_primary[@]}"; do
            [[ -n "${content_mirror[$content]:-}" ]] || return 1
            if [[ "${content_primary[$content]}" == "${content_mirror[$content]}" ]]; then
                log_error "Primary and Mirror share a host for content ${content}"
                return 1
            fi
        done
    fi
    log_success "Official topology passed structural and safety validation"
}

print_cluster_topology() {
    local record content dbid host address port data role
    printf '\n================================================\n'
    printf 'Cloudberry Official Cluster Topology\n'
    printf '================================================\n\n'
    IFS='|' read -r content dbid host address port data role <<< "$PARSED_COORDINATOR"
    printf 'Coordinator\n--------------------------------\n'
    printf 'Host       : %s\nAddress    : %s\nPort       : %s\nData       : %s\n\n' \
        "$host" "$address" "$port" "$data"

    printf 'Primary Segments\n--------------------------------\n'
    printf '%-9s %-18s %-8s %s\n' "Content" "Host" "Port" "Data"
    for record in "${PRIMARY_SEGMENTS[@]}"; do
        IFS='|' read -r content dbid host address port data role <<< "$record"
        printf '%-9s %-18s %-8s %s\n' "$content" "$host" "$port" "$data"
    done

    if [[ ${#MIRROR_SEGMENTS[@]} -gt 0 ]]; then
        printf '\nMirror Segments\n--------------------------------\n'
        printf '%-9s %-18s %-8s %s\n' "Content" "Host" "Port" "Data"
        for record in "${MIRROR_SEGMENTS[@]}"; do
            IFS='|' read -r content dbid host address port data role <<< "$record"
            printf '%-9s %-18s %-8s %s\n' "$content" "$host" "$port" "$data"
        done
    fi
}

generate_official_topology() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '\n[DRY-RUN] Official topology is intentionally not generated because gpinitsystem -O performs remote checks.\n'
        local -a preview=("${CBDB_HOME}/bin/gpinitsystem" -a -c "$GPINIT_CONFIG" -h "$GPINIT_HOSTFILE")
        [[ "$MIRROR_ENABLED" == "true" ]] && preview+=(--mirror-mode="$MIRROR_MODE")
        preview+=(-O "$GPINIT_INPUT")
        printf '[DRY-RUN] Would run: %s\n' "$(format_command "${preview[@]}")"
        return 0
    fi

    rm -f -- "$GPINIT_INPUT"
    local -a command=("${CBDB_HOME}/bin/gpinitsystem" -a -c "$GPINIT_CONFIG" -h "$GPINIT_HOSTFILE")
    [[ "$MIRROR_ENABLED" == "true" ]] && command+=(--mirror-mode="$MIRROR_MODE")
    command+=(-O "$GPINIT_INPUT" -l "$LOG_DIR")
    run_gp_command "${command[@]}" || return 1
    chmod 600 "$GPINIT_INPUT" 2>/dev/null || true
    parse_gpinitsystem_input || return 1
    INSTALL_STATE="ready"
    save_config "ready"
}

wait_for_initial_segment_health() {
    local expected_count=$(( ${#PRIMARY_SEGMENTS[@]} + ${#MIRROR_SEGMENTS[@]} ))
    local health_condition="status = 'u'"
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        health_condition="status = 'u' AND mode = 's'"
    fi

    local query
    query="SELECT count(*) || '|' || count(*) FILTER (WHERE NOT (${health_condition})) FROM gp_segment_configuration WHERE content >= 0;"
    local deadline=$((SECONDS + INITIAL_HEALTH_TIMEOUT))
    local attempt=0 output total_count unhealthy_count
    log_info "Waiting for ${expected_count} Segment instances to reach the intended initial state"

    while (( SECONDS < deadline )); do
        ((attempt++))
        if output="$(capture_gp_command "${CBDB_HOME}/bin/psql" -XAtq -v ON_ERROR_STOP=1 \
            -d postgres -c "$query")"; then
            output="$(trim "$output")"
            IFS='|' read -r total_count unhealthy_count <<< "$output"
            if [[ "$total_count" =~ ^[0-9]+$ && "$unhealthy_count" =~ ^[0-9]+$ ]] && \
                    (( total_count == expected_count && unhealthy_count == 0 )); then
                if [[ "$MIRROR_ENABLED" == "true" ]]; then
                    log_success "All ${total_count} Primary/Mirror instances are Up and synchronized"
                else
                    log_success "All ${total_count} Primary instances are Up"
                fi
                return 0
            fi
        fi

        if (( attempt == 1 || attempt % 10 == 0 )); then
            log_info "Initial Segment health is not ready yet: ${output:-query unavailable}"
        fi
        sleep "$INITIAL_HEALTH_INTERVAL"
    done

    log_error "Initial Segment health did not converge within ${INITIAL_HEALTH_TIMEOUT} seconds"
    run_gp_command "${CBDB_HOME}/bin/gpstate" -b -d "$COORDINATOR_DATA_DIRECTORY" || true
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        run_gp_command "${CBDB_HOME}/bin/gpstate" -m -d "$COORDINATOR_DATA_DIRECTORY" || true
        run_gp_command "${CBDB_HOME}/bin/gpstate" -e -d "$COORDINATOR_DATA_DIRECTORY" || true
    fi
    return 1
}

initialize_cluster() {
    [[ -O "$GPINIT_INPUT" ]] || { log_error "Official topology file is not owned by the current user"; return 1; }
    chmod 600 "$GPINIT_INPUT" || return 1
    parse_gpinitsystem_input || return 1
    local -a command=("${CBDB_HOME}/bin/gpinitsystem" -a -I "$GPINIT_INPUT" -l "$LOG_DIR")
    run_gp_command "${command[@]}" || return 1
    wait_for_initial_segment_health || return 1

    # This Cloudberry gpinitsystem release can invoke gpinitstandby with an
    # empty `-f` value when the default internal FTS configuration is used.
    # Initialize the core array first, then call gpinitstandby directly so its
    # exit status cannot be hidden by a successful core-array initialization.
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        run_gp_command "${CBDB_HOME}/bin/gpinitstandby" -a \
            -s "$STANDBY_HOST" \
            -P "$COORDINATOR_PORT" \
            -S "$STANDBY_DATA_DIRECTORY" \
            -l "$LOG_DIR" || return 1

        verify_standby_catalog || return 1

        local standby_pid_check='datadir="$1"; pidfile="${datadir}/postmaster.pid"; test -r "$pidfile" || exit 1; IFS= read -r pid < "$pidfile"; case "$pid" in ""|*[!0-9]*) exit 1;; esac; kill -0 "$pid"'
        if ! run_remote "$STANDBY_HOST" bash -c "$standby_pid_check" bash "$STANDBY_DATA_DIRECTORY"; then
            log_error "Standby catalog entry exists, but its postmaster process is not running: ${STANDBY_HOST}"
            return 1
        fi
        run_gp_command "${CBDB_HOME}/bin/gpstate" -f -d "$COORDINATOR_DATA_DIRECTORY" || return 1
        log_success "Standby Coordinator initialized and verified: ${STANDBY_HOST}"
    fi

    if [[ "$DATABASE_NAME" != "postgres" ]]; then
        run_gp_command "${CBDB_HOME}/bin/createdb" -p "$COORDINATOR_PORT" "$DATABASE_NAME" || return 1
    fi
    run_gp_command "${CBDB_HOME}/bin/gpstate" -b -d "$COORDINATOR_DATA_DIRECTORY"
}

verify_standby_catalog() {
    [[ "$STANDBY_ENABLED" == "true" ]] || return 0
    local standby_sql
    standby_sql="DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM gp_segment_configuration WHERE content = -1 AND role = 'm' AND hostname = '${STANDBY_HOST}' AND port = ${COORDINATOR_PORT} AND datadir = '${STANDBY_DATA_DIRECTORY}') THEN RAISE EXCEPTION 'configured standby does not match the intended topology'; END IF; END \$\$;"
    if ! run_gp_command "${CBDB_HOME}/bin/psql" -X -v ON_ERROR_STOP=1 \
        -p "$COORDINATOR_PORT" -d postgres -c "$standby_sql"; then
        log_error "Configured Standby is absent from the coordinator catalog or does not match: ${STANDBY_HOST}"
        return 1
    fi
    log_success "Standby catalog entry matches the intended topology: ${STANDBY_HOST}"
}

###############################################################################
# Installation orchestration
###############################################################################

ensure_install_can_start() {
    if [[ ! -f "$INSTALL_CONF" ]]; then
        return 0
    fi
    local saved_state
    saved_state="$(awk -F= '$1 == "install_state" {print $2; exit}' "$INSTALL_CONF")"
    case "$saved_state" in
        installed)
            log_error "检测到已安装集群。请先查看状态或卸载，不能覆盖安装。"
            return 1
            ;;
        ready|failed)
            log_error "检测到状态为 ${saved_state} 的安装现场。为保护数据，本次不覆盖。"
            log_error "请检查 ${INSTALL_CONF}、数据目录和日志后处理。"
            return 1
            ;;
        *) return 0 ;;
    esac
}

install_cluster() {
    local mode="$1"
    ensure_install_can_start || return 1

    print_stage 1 11 "Collecting configuration"
    case "$mode" in
        demo) generate_demo_topology || return 1 ;;
        fast) generate_fast_topology || return 1 ;;
        custom) generate_custom_topology || return 1 ;;
        *) return 1 ;;
    esac
    print_intended_topology
    confirm "Continue with this intended configuration?" "N" || return 0

    print_stage 2 11 "Generating host and initialization files"
    generate_hostfile || return 1
    generate_gpinitsystem_config || return 1
    generate_ssh_transport_files || return 1
    validate_ssh_transport_resolution || return 1
    save_config "planned" || return 1

    if [[ "$DRY_RUN" == "true" ]]; then
        print_stage 3 11 "Dry-run local validation"
        check_local_dependencies_for_dry_run || return 1
        print_stage 4 11 "Printing intended topology"
        print_intended_topology
        print_stage 5 11 "Printing official commands"
        generate_official_topology || return 1
        local -a init_preview=("${CBDB_HOME}/bin/gpinitsystem" -a -I "$GPINIT_INPUT" -l "$LOG_DIR")
        printf '[DRY-RUN] Would run after official topology confirmation: %s\n' \
            "$(format_command "${init_preview[@]}")"
        if [[ "$STANDBY_ENABLED" == "true" ]]; then
            local -a standby_preview=("${CBDB_HOME}/bin/gpinitstandby" -a \
                -s "$STANDBY_HOST" -P "$COORDINATOR_PORT" -S "$STANDBY_DATA_DIRECTORY" \
                -l "$LOG_DIR")
            printf '[DRY-RUN] Would initialize Standby after the core array: %s\n' \
                "$(format_command "${standby_preview[@]}")"
        fi
        log_success "Dry-run completed without remote access or cluster changes"
        return 0
    fi

    print_stage 3 11 "Checking local user and dependencies"
    check_current_user || return 1
    check_coordinator_is_local || return 1
    check_dependencies || return 1

    print_stage 4 11 "Preparing password-free SSH"
    prepare_hosts || return 1

    print_stage 5 11 "Checking resources and ports"
    check_resources
    check_ports || return 1

    print_stage 6 11 "Checking or distributing Cloudberry binary"
    distribute_binary || return 1

    print_stage 7 11 "Checking and preparing data directories"
    check_directories || return 1
    prepare_directories || return 1

    print_stage 8 11 "Generating official topology with gpinitsystem -O"
    if ! generate_official_topology; then
        save_config "failed" || true
        return 1
    fi

    print_stage 9 11 "Reviewing official topology"
    print_cluster_topology
    if ! confirm "Initialize the cluster now using this topology? Choosing N cancels installation." "N"; then
        save_config "planned" || return 1
        log_warn "Installation cancelled by user; gpinitsystem -I was not executed"
        log_info "Prepared directories and topology files were retained; run the installation again to retry"
        return 0
    fi

    print_stage 10 11 "Initializing Cloudberry with gpinitsystem -I"
    if ! initialize_cluster; then
        save_config "failed" || true
        log_error "Initialization failed. Data directories were preserved for diagnosis."
        log_error "Review log: ${LOG_FILE}"
        return 1
    fi

    print_stage 11 11 "Saving installed cluster state"
    save_config "installed" || return 1
    if generate_cluster_env_file; then
        print_cluster_env_usage
    else
        log_warn "Cluster installation succeeded, but the convenience environment file could not be generated"
        log_warn "Use -d ${COORDINATOR_DATA_DIRECTORY} or export COORDINATOR_DATA_DIRECTORY manually"
    fi
    log_success "Apache Cloudberry cluster installation completed"
}

###############################################################################
# Cluster lifecycle and uninstall
###############################################################################

require_installed_config() {
    load_config || return 1
    if [[ "$INSTALL_STATE" != "installed" ]]; then
        log_error "集群配置状态不是 installed: ${INSTALL_STATE}"
        return 1
    fi
    check_current_user || return 1
    check_coordinator_is_local
}

start_cluster() {
    require_installed_config || return 1
    run_gp_command "${CBDB_HOME}/bin/gpstart" -a -d "$COORDINATOR_DATA_DIRECTORY"
}

stop_cluster() {
    require_installed_config || return 1
    printf '\nStop mode:\n1. fast (default)\n2. smart\n3. immediate (dangerous)\n'
    read_int "Select stop mode" 1 1 3 || return 1
    local mode
    case "$READ_VALUE" in
        1) mode="fast" ;;
        2) mode="smart" ;;
        3)
            mode="immediate"
            log_warn "Immediate shutdown can require recovery and may cause data loss"
            require_phrase "High-risk shutdown requested." "IMMEDIATE" || return 0
            ;;
    esac
    run_gp_command "${CBDB_HOME}/bin/gpstop" -a -M "$mode" -d "$COORDINATOR_DATA_DIRECTORY"
}

status_cluster() {
    require_installed_config || return 1
    inspect_cluster_runtime_state || return 1
    case "$CLUSTER_RUNTIME_STATE" in
        RUNNING)
            verify_standby_catalog || return 1
            ;;
        STOPPED)
            check_installed_directories || return 1
            log_success "Coordinator and all segment processes are stopped"
            return 0
            ;;
        PARTIALLY_RUNNING)
            log_error "Cluster status is inconsistent; inspect the listed instances before starting or stopping the cluster"
            return 1
            ;;
        *)
            log_error "Unable to classify cluster state: ${CLUSTER_RUNTIME_STATE}"
            return 1
            ;;
    esac

    printf '\nStatus view:\n1. Brief\n2. Detailed\n'
    read_int "Select status view" 1 1 2 || return 1
    if [[ "$READ_VALUE" == "1" ]]; then
        run_gp_command "${CBDB_HOME}/bin/gpstate" -b -d "$COORDINATOR_DATA_DIRECTORY"
        return
    fi

    run_gp_command "${CBDB_HOME}/bin/gpstate" -s -d "$COORDINATOR_DATA_DIRECTORY" || return 1
    run_gp_command "${CBDB_HOME}/bin/gpstate" -c -d "$COORDINATOR_DATA_DIRECTORY" || return 1
    if [[ "$MIRROR_ENABLED" == "true" ]]; then
        run_gp_command "${CBDB_HOME}/bin/gpstate" -m -d "$COORDINATOR_DATA_DIRECTORY" || return 1
        run_gp_command "${CBDB_HOME}/bin/gpstate" -e -d "$COORDINATOR_DATA_DIRECTORY" || true
    fi
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        run_gp_command "${CBDB_HOME}/bin/gpstate" -f -d "$COORDINATOR_DATA_DIRECTORY" || true
    fi
}

show_cluster_config() {
    load_config || return 1
    print_intended_topology
    printf '\nInstall state          : %s\n' "$INSTALL_STATE"
    printf 'Configuration file     : %s\n' "$INSTALL_CONF"
    if [[ -f "$CLUSTER_ENV_FILE" ]]; then
        printf 'Cluster env file       : %s\n' "$CLUSTER_ENV_FILE"
    else
        printf 'Cluster env file       : %s (not generated)\n' "$CLUSTER_ENV_FILE"
    fi
    printf 'Official topology file : %s\n' "$GPINIT_INPUT"
    if [[ -s "$GPINIT_INPUT" ]] && parse_gpinitsystem_input; then
        print_cluster_topology
    else
        log_warn "Official topology is not available or could not be parsed"
    fi
}

is_path_within() {
    local path="$1"
    local root="$2"
    path="$(canonicalize_path "$path")"
    root="$(canonicalize_path "$root")"
    [[ "$path" == "$root" || "$path" == "${root}/"* ]]
}

safe_remove_directory() {
    local path="$1"
    local allowed_root="$2"
    path="$(canonicalize_path "$path")"
    allowed_root="$(canonicalize_path "$allowed_root")"
    validate_path "$path" || { log_error "Unsafe deletion path: ${path}"; return 1; }
    validate_path "$allowed_root" || return 1
    [[ "$path" != "/" && "$path" != "/home" && "$path" != "${HOME}" ]] || {
        log_error "Refusing to delete protected path: ${path}"
        return 1
    }
    [[ "$path" != "$SCRIPT_DIR" && "$path" != "$CBDB_HOME" ]] || {
        log_error "Refusing to delete protected application path: ${path}"
        return 1
    }
    is_path_within "$path" "$allowed_root" || {
        log_error "Deletion path is outside allowed root ${allowed_root}: ${path}"
        return 1
    }
    [[ "$path" != "$allowed_root" ]] || {
        log_error "Refusing to delete the entire allowed root without a more specific path"
        return 1
    }

    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[DRY-RUN] Would safely remove: %s\n' "$path"
        return 0
    fi
    [[ -e "$path" ]] || return 0
    find "$path" -depth -delete
}

safe_remove_binary() {
    local path
    path="$(canonicalize_path "$1")"
    validate_path "$path" || return 1
    [[ "$path" == "$CBDB_HOME" ]] || return 1
    case "$path" in
        /|/usr|/usr/local|/opt|/home|"$HOME"|"$SCRIPT_DIR")
            log_error "Refusing to delete protected binary path: ${path}"
            return 1
            ;;
    esac
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[DRY-RUN] Would safely remove binary directory: %s\n' "$path"
        return 0
    fi
    [[ -d "$path" ]] || return 0
    find "$path" -depth -delete
}

coordinator_accepts_connections() {
    local pg_isready="${CBDB_HOME}/bin/pg_isready"
    [[ -x "$pg_isready" ]] || return 1

    local gp_lib="${CBDB_HOME}/lib"
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        gp_lib+="${gp_lib:+:}${LD_LIBRARY_PATH}"
    fi
    env "LD_LIBRARY_PATH=${gp_lib}" \
        "$pg_isready" -q -h localhost -p "$COORDINATOR_PORT"
}

remove_empty_cluster_directory() {
    local host="$1"
    local path
    path="$(canonicalize_path "$2")"

    validate_path "$path" || {
        log_error "Refusing to clean invalid directory path on ${host}: ${path}"
        return 1
    }
    [[ "$path" != "/" && "$path" != "/home" && "$path" != "$HOME" ]] || {
        log_error "Refusing to clean protected directory on ${host}: ${path}"
        return 1
    }
    [[ "$path" != "$SCRIPT_DIR" && "$path" != "$CBDB_HOME" ]] || {
        log_error "Refusing to clean application directory on ${host}: ${path}"
        return 1
    }
    is_path_within "$path" "$CBDB_DATA_HOME" || {
        log_error "Cleanup path is outside configured data root on ${host}: ${path}"
        return 1
    }

    local script result
    script='path="$1"; if [ ! -e "$path" ] && [ ! -L "$path" ]; then printf "absent"; elif [ -L "$path" ] || [ ! -d "$path" ]; then printf "not-directory"; elif find "$path" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then printf "not-empty"; elif rmdir -- "$path"; then printf "removed"; else printf "failed"; exit 1; fi'
    log_info "Checking removable empty directory on ${host}: ${path}"
    result="$(capture_remote "$host" bash -c "$script" bash "$path")" || {
        log_error "Failed to check or remove empty directory on ${host}: ${path}"
        return 1
    }
    case "$result" in
        removed) log_success "Removed empty directory on ${host}: ${path}" ;;
        absent) ;;
        not-empty) log_warn "Retaining non-empty directory on ${host}: ${path}" ;;
        not-directory) log_warn "Retaining path because it is not a real directory on ${host}: ${path}" ;;
        *)
            log_error "Unexpected empty-directory cleanup result on ${host}: ${path} (${result})"
            return 1
            ;;
    esac
}

cleanup_cluster_parent_directories() {
    local host path record key failed=0
    declare -A checked=()

    cleanup_one() {
        host="$1"
        path="$(canonicalize_path "$2")"
        key="${host}|${path}"
        [[ -z "${checked[$key]:-}" ]] || return 0
        checked["$key"]=1
        remove_empty_cluster_directory "$host" "$path" || failed=1
    }

    # Remove the role-specific parent directories first. The configured data
    # root can only become empty after all of these checks have completed.
    cleanup_one "$COORDINATOR_HOST" "$COORDINATOR_DIRECTORY"
    for host in "${SEGMENT_HOSTS[@]}"; do
        cleanup_one "$host" "$SEGMENT_DATA_DIRECTORY"
        if [[ "$MIRROR_ENABLED" == "true" ]]; then
            cleanup_one "$host" "$MIRROR_DATA_DIRECTORY"
        fi
    done
    if [[ "$STANDBY_ENABLED" == "true" ]]; then
        cleanup_one "$STANDBY_HOST" "$(dirname "$STANDBY_DATA_DIRECTORY")"
    fi

    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        cleanup_one "$host" "$CBDB_DATA_HOME"
    done
    unset -f cleanup_one
    (( failed == 0 ))
}

delete_cloudberry_binary_if_requested() {
    if ! confirm "Also delete Cloudberry binary from all configured hosts?" "N"; then
        log_success "Cloudberry binary retained: ${CBDB_HOME}"
        return 0
    fi
    if ! require_phrase "This removes ${CBDB_HOME} from every configured host." "DELETE BINARY"; then
        log_warn "Cloudberry binary deletion skipped: confirmation phrase did not match DELETE BINARY"
        log_success "Cloudberry binary retained: ${CBDB_HOME}"
        return 0
    fi

    log_info "Deleting Cloudberry binary from all configured hosts: ${CBDB_HOME}"
    local record host script
    script='path="$1"; case "$path" in /|/usr|/usr/local|/opt|/home) exit 2;; esac; [ -d "$path" ] || exit 0; find "$path" -depth -delete'
    for record in "${HOSTS[@]}"; do
        host="${record%%|*}"
        if [[ "$host" == "$COORDINATOR_HOST" ]]; then
            continue
        fi
        run_remote "$host" bash -c "$script" bash "$CBDB_HOME" || return 1
    done
    safe_remove_binary "$CBDB_HOME" || return 1
    log_success "Cloudberry binary deletion completed: ${CBDB_HOME}"
}

uninstall_cluster() {
    load_config || return 1
    check_current_user || return 1
    check_coordinator_is_local || return 1

    if [[ "$INSTALL_STATE" == "uninstalled" ]]; then
        log_success "Cluster data is already marked as uninstalled"
        remove_cluster_env_file || true
        delete_cloudberry_binary_if_requested || return 1
        log_success "Cluster uninstall workflow completed"
        return 0
    fi

    printf '\nWARNING\n\nThis operation will permanently delete cluster data managed from:\n'
    printf '  Coordinator: %s\n' "$COORDINATOR_DATA_DIRECTORY"
    printf '  Primary root: %s\n' "$SEGMENT_DATA_DIRECTORY"
    [[ "$MIRROR_ENABLED" == "true" ]] && printf '  Mirror root: %s\n' "$MIRROR_DATA_DIRECTORY"
    [[ "$STANDBY_ENABLED" == "true" ]] && printf '  Standby: %s\n' "$STANDBY_DATA_DIRECTORY"
    printf '\nCloudberry binary will NOT be deleted by default.\n'
    if ! require_phrase "Confirm permanent cluster data deletion." "DELETE"; then
        log_warn "Cluster data deletion cancelled: confirmation phrase did not match DELETE"
        return 0
    fi

    # gpdeletesystem discovers the segment topology by connecting to the
    # coordinator before it stops processes and removes data.  A cluster that
    # was stopped beforehand must therefore be started briefly for the
    # official deletion path to work.
    if [[ "$DRY_RUN" != "true" ]] && ! coordinator_accepts_connections; then
        log_warn "Coordinator is not accepting connections on localhost:${COORDINATOR_PORT}."
        log_warn "gpdeletesystem requires a running coordinator to discover the segment topology."
        if ! confirm "Start the cluster temporarily before deletion?" "Y"; then
            log_error "Cluster deletion cancelled; no data directories were removed."
            return 1
        fi
        run_gp_command "${CBDB_HOME}/bin/gpstart" -a -d "$COORDINATOR_DATA_DIRECTORY" || {
            log_error "Unable to start the cluster for gpdeletesystem topology discovery."
            log_error "No automatic recursive fallback was attempted. Inspect: ${LOG_FILE}"
            return 1
        }
    fi

    if ! run_gp_command "${CBDB_HOME}/bin/gpdeletesystem" -d "$COORDINATOR_DATA_DIRECTORY"; then
        log_error "gpdeletesystem failed. No automatic recursive fallback was attempted."
        log_error "Inspect the cluster and logs before retrying: ${LOG_FILE}"
        return 1
    fi
    if ! cleanup_cluster_parent_directories; then
        log_warn "Cluster data was deleted, but one or more empty parent directories could not be cleaned."
    fi
    save_config "uninstalled" || return 1
    remove_cluster_env_file || true
    log_success "Cluster data deletion completed"
    delete_cloudberry_binary_if_requested || return 1
    log_success "Cluster uninstall workflow completed"
}

###############################################################################
# Environment check menu
###############################################################################

environment_check_menu() {
    printf '\nEnvironment check uses pre-installation or runtime checks according to configuration state.\n'
    if [[ -f "$INSTALL_CONF" ]] && confirm "Load ${INSTALL_CONF}?" "Y"; then
        load_config || return 1
    else
        reset_host_model
        INSTALL_MODE="check"
        input_base_config "false" || return 1
        local host_count index role host
        read_int "Host count" 1 1 256 || return 1
        host_count="$READ_VALUE"
        for ((index = 1; index <= host_count; index++)); do
            role="segment"
            (( index == 1 )) && role="coordinator"
            input_one_host "$index" "$role" || return 1
            host="$READ_VALUE"
            if (( index == 1 )); then
                COORDINATOR_HOST="$host"
                COORDINATOR_IP="${HOST_IP[$host]}"
            else
                SEGMENT_HOSTS+=("$host")
            fi
        done
        if [[ ${#SEGMENT_HOSTS[@]} -eq 0 ]]; then
            SEGMENT_HOSTS=("$COORDINATOR_HOST")
            HOST_ROLE["$COORDINATOR_HOST"]="coordinator,segment"
            rebuild_host_records
        fi
        generate_hostfile || return 1
        generate_ssh_transport_files || return 1
        validate_ssh_transport_resolution || return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        check_local_dependencies_for_dry_run
        return
    fi
    if [[ "$(id -u)" == "0" ]]; then
        if [[ "$INSTALL_STATE" == "installed" ]]; then
            log_error "Installed cluster runtime checks must be executed as ${CBDB_USER}, not root"
            return 1
        fi
        prepare_system_as_root
        return
    fi
    check_environment
}

###############################################################################
# Menu and entry point
###############################################################################

show_main_menu() {
    printf '\n================================================\n'
    printf ' Apache Cloudberry Cluster Tool\n'
    printf '================================================\n'
    printf '1. Demo 单机安装\n'
    printf '2. 快速集群安装\n'
    printf '3. 自定义集群安装\n'
    printf '4. 启动集群\n'
    printf '5. 停止集群\n'
    printf '6. 查看集群状态\n'
    printf '7. 查看集群配置\n'
    printf '8. 卸载集群\n'
    printf '9. 环境检查（安装前/运行中）\n'
    printf '0. 退出\n'
}

usage() {
    cat <<'EOF'
Usage: ./cloudberry_tool.sh [--dry-run] [--help]

  --dry-run  Generate local configuration and print planned commands only.
             It never connects to remote hosts or runs gp lifecycle tools.
  --help     Show this help.
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) DRY_RUN="true" ;;
            --help|-h) usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage; return 1 ;;
        esac
        shift
    done
}

handle_action_failure() {
    local action="$1"
    log_error "${action} failed"
    log_error "Current stage: ${CURRENT_STAGE:-not available}"
    log_error "Log: ${LOG_FILE}"
}

main() {
    init_globals
    init_runtime_directories || exit 1
    parse_arguments "$@" || exit 2
    trap 'printf "\nInterrupted. No automatic cleanup was performed.\n"; exit 130' INT TERM

    [[ "$DRY_RUN" == "true" ]] && log_warn "DRY-RUN mode enabled: no remote or cluster-changing command will run"

    local choice
    while true; do
        show_main_menu
        read_int "Select menu item" 0 0 9 || break
        choice="$READ_VALUE"
        case "$choice" in
            1) install_cluster demo || handle_action_failure "Demo installation" ;;
            2) install_cluster fast || handle_action_failure "Fast installation" ;;
            3) install_cluster custom || handle_action_failure "Custom installation" ;;
            4) start_cluster || handle_action_failure "Cluster start" ;;
            5) stop_cluster || handle_action_failure "Cluster stop" ;;
            6) status_cluster || handle_action_failure "Cluster status" ;;
            7) show_cluster_config || handle_action_failure "Show configuration" ;;
            8) uninstall_cluster || handle_action_failure "Cluster uninstall" ;;
            9) environment_check_menu || handle_action_failure "Environment check" ;;
            0) log_info "Exiting"; return 0 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
