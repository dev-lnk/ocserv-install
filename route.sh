#!/usr/bin/env bash
set -Eeuo pipefail

GROUP_NAME="bypass-ru"
OCSERV_CONF="/etc/ocserv/ocserv.conf"
OCPASSWD="/etc/ocserv/ocpasswd"
GROUP_DIR="/etc/ocserv/config-per-group"
DEFAULTS_DIR="/etc/ocserv/defaults"
DEFAULT_GROUP_FILE="${DEFAULTS_DIR}/group.conf"
LOCAL_INCLUDE="/etc/ocserv/route-bypass-ru.include"
LOCAL_EXCLUDE="/etc/ocserv/route-bypass-ru.exclude"
STATE_DIR="/var/lib/ocserv-bypass-ru"
LOG_FILE="/var/log/ocserv-bypass-ru.log"
UPDATER="/usr/local/sbin/update-ocserv-bypass-ru.sh"
CRON_FILE="/etc/cron.d/ocserv-bypass-ru"
LOCK_FILE="/run/lock/ocserv-route-setup.lock"
DEFAULT_MAX_ROUTES="${MAX_ROUTES:-0}"
DEFAULT_ROUTE_SOURCE_MODE="${ROUTE_SOURCE_MODE:-subnets}"

log() {
  printf '[route.sh] %s\n' "$*"
}

die() {
  printf '[route.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -n bash "$0" "$@"
    fi

    die "run this script as root, for example: sudo ./route.sh"
  fi
}

require_command() {
  local command_name="$1"

  command -v "${command_name}" >/dev/null 2>&1 || die "required command is missing: ${command_name}"
}

backup_file() {
  local file_path="$1"

  if [ -f "${file_path}" ]; then
    cp -a "${file_path}" "${file_path}.bak.$(date +%F-%H%M%S)"
    log "backup created: ${file_path}"
  fi
}

configure_ocserv_conf() {
  [ -f "${OCSERV_CONF}" ] || die "${OCSERV_CONF} not found"

  local tmp_file
  tmp_file="$(mktemp)"

  awk \
    -v config_per_group="config-per-group = /etc/ocserv/config-per-group/" \
    -v default_group_config="default-group-config = /etc/ocserv/defaults/group.conf" '
      BEGIN {
        wrote_config_per_group = 0
        wrote_default_group_config = 0
      }

      /^[[:space:]]*#?[[:space:]]*config-per-group[[:space:]]*=/ {
        if (!wrote_config_per_group) {
          print config_per_group
          wrote_config_per_group = 1
        }
        next
      }

      /^[[:space:]]*#?[[:space:]]*default-group-config[[:space:]]*=/ {
        if (!wrote_default_group_config) {
          print default_group_config
          wrote_default_group_config = 1
        }
        next
      }

      /^[[:space:]]*(select-group|default-select-group|auto-select-group)[[:space:]]*=/ {
        print "# disabled by route.sh: " $0
        next
      }

      { print }

      END {
        if (!wrote_config_per_group) {
          print ""
          print config_per_group
        }
        if (!wrote_default_group_config) {
          print default_group_config
        }
      }
    ' "${OCSERV_CONF}" > "${tmp_file}"

  install -m 0640 -o root -g root "${tmp_file}" "${OCSERV_CONF}"
  rm -f "${tmp_file}"
  log "updated ${OCSERV_CONF}"
}

write_minimal_group_config() {
  local tmp_file
  tmp_file="$(mktemp)"

  mkdir -p "${GROUP_DIR}" "${DEFAULTS_DIR}"

  cat > "${tmp_file}" <<EOF
# Managed by route.sh
# Minimal fallback profile for ${GROUP_NAME}.

route = default
tunnel-all-dns = true
dns = 1.1.1.1
dns = 8.8.8.8
EOF

  if [ -f "${GROUP_DIR}/${GROUP_NAME}" ]; then
    mkdir -p "${STATE_DIR}/backup"
    cp -a "${GROUP_DIR}/${GROUP_NAME}" "${STATE_DIR}/backup/${GROUP_NAME}.minimal-fallback.$(date +%F-%H%M%S)"
  fi

  install -m 0640 -o root -g root "${tmp_file}" "${GROUP_DIR}/${GROUP_NAME}"
  rm -f "${tmp_file}"
  ln -sfn "${GROUP_DIR}/${GROUP_NAME}" "${DEFAULT_GROUP_FILE}"
}

reload_ocserv() {
  ocserv -t -c "${OCSERV_CONF}"

  if systemctl reload ocserv 2>/dev/null; then
    log "ocserv reloaded"
  else
    systemctl restart ocserv
    log "ocserv restarted"
  fi
}

rescue_connection() {
  require_root "$@"
  require_command install
  require_command ocserv
  require_command systemctl

  backup_file "${OCSERV_CONF}"
  backup_file "${OCPASSWD}"
  configure_ocserv_conf
  write_minimal_group_config
  reload_ocserv

  log "rescue profile installed; reconnect the VPN client now"
}

disable_route_layer() {
  [ -f "${OCSERV_CONF}" ] || die "${OCSERV_CONF} not found"

  local tmp_file
  tmp_file="$(mktemp)"

  awk '
    /^[[:space:]]*config-per-group[[:space:]]*=/ {
      print "# disabled by route.sh rollback: " $0
      next
    }

    /^[[:space:]]*default-group-config[[:space:]]*=/ {
      print "# disabled by route.sh rollback: " $0
      next
    }

    { print }
  ' "${OCSERV_CONF}" > "${tmp_file}"

  install -m 0640 -o root -g root "${tmp_file}" "${OCSERV_CONF}"
  rm -f "${tmp_file}"
  log "disabled route layer in ${OCSERV_CONF}"
}

rollback_route_layer() {
  require_root "$@"
  require_command install
  require_command ocserv
  require_command systemctl

  backup_file "${OCSERV_CONF}"
  backup_file "${OCPASSWD}"
  disable_route_layer

  if [ -f "${CRON_FILE}" ]; then
    mv "${CRON_FILE}" "${CRON_FILE}.disabled.$(date +%F-%H%M%S)"
    log "disabled cron job: ${CRON_FILE}"
  fi

  reload_ocserv
  log "routing layer rolled back; reconnect the VPN client now"
}

install_updater() {
  mkdir -p "$(dirname "${UPDATER}")"

  cat > "${UPDATER}" <<'UPDATER_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

LOCK_FILE="/run/lock/ocserv-bypass-ru.lock"
mkdir -p "$(dirname "${LOCK_FILE}")"
exec 9>"${LOCK_FILE}"
flock -n 9 || exit 0

OCSERV_CONF="/etc/ocserv/ocserv.conf"

GROUP_NAME="bypass-ru"
GROUP_DIR="/etc/ocserv/config-per-group"
GROUP_FILE="${GROUP_DIR}/${GROUP_NAME}"

DEFAULTS_DIR="/etc/ocserv/defaults"
DEFAULT_GROUP_FILE="${DEFAULTS_DIR}/group.conf"

STATE_DIR="/var/lib/ocserv-bypass-ru"
BACKUP_DIR="${STATE_DIR}/backup"

LOCAL_INCLUDE="/etc/ocserv/route-bypass-ru.include"
LOCAL_EXCLUDE="/etc/ocserv/route-bypass-ru.exclude"

MIN_ROUTES="${MIN_ROUTES:-20}"
MAX_ROUTES="${MAX_ROUTES:-0}"
ROUTE_SOURCE_MODE="${ROUTE_SOURCE_MODE:-subnets}"

case "${ROUTE_SOURCE_MODE}" in
  subnets)
    URLS=(
      "https://antifilter.download/list/subnet.lst"
      "https://community.antifilter.download/list/community.lst"
      "https://raw.githubusercontent.com/1andrevich/Re-filter-lists/refs/heads/main/ipsum.lst"
    )
    ;;
  full)
    URLS=(
      "https://antifilter.download/list/ipresolve.lst"
      "https://antifilter.download/list/subnet.lst"
      "https://community.antifilter.download/list/community.lst"
      "https://raw.githubusercontent.com/1andrevich/Re-filter-lists/refs/heads/main/ipsum.lst"
    )
    ;;
  *)
    echo "ERROR: ROUTE_SOURCE_MODE must be subnets or full" >&2
    exit 1
    ;;
esac

TMP_DIR="$(mktemp -d)"
RAW_INPUT="${TMP_DIR}/raw_input.txt"
RAW_EXCLUDE="${TMP_DIR}/raw_exclude.txt"
NORMALIZED="${TMP_DIR}/normalized.txt"
EXCLUDE_NORMALIZED="${TMP_DIR}/exclude_normalized.txt"
FILTERED="${TMP_DIR}/filtered.txt"
LIMITED="${TMP_DIR}/limited.txt"
NEW_GROUP_FILE="${TMP_DIR}/${GROUP_NAME}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${GROUP_DIR}" "${DEFAULTS_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
: > "${RAW_INPUT}"
: > "${RAW_EXCLUDE}"

for url in "${URLS[@]}"; do
  echo "Downloading: ${url}" >&2
  curl -fsSL \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 120 \
    "${url}" >> "${RAW_INPUT}"
  printf '\n' >> "${RAW_INPUT}"
done

if [ -f "${LOCAL_INCLUDE}" ]; then
  cat "${LOCAL_INCLUDE}" >> "${RAW_INPUT}"
  printf '\n' >> "${RAW_INPUT}"
fi

if [ -f "${LOCAL_EXCLUDE}" ]; then
  cat "${LOCAL_EXCLUDE}" >> "${RAW_EXCLUDE}"
  printf '\n' >> "${RAW_EXCLUDE}"
fi

normalize_routes() {
  local input_file="$1"

  { grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2}|/([0-9]{1,3}\.){3}[0-9]{1,3})?' "${input_file}" || true; } \
    | awk '
      function valid_ip(ip, a, i) {
        if (split(ip, a, ".") != 4) return 0
        for (i = 1; i <= 4; i++) {
          if (a[i] !~ /^[0-9]+$/) return 0
          if (a[i] < 0 || a[i] > 255) return 0
        }
        return 1
      }

      function octet_from_bits(bits, value, i) {
        if (bits <= 0) return 0
        if (bits >= 8) return 255
        value = 0
        for (i = 7; i >= 8 - bits; i--) {
          value += 2 ^ i
        }
        return value
      }

      function prefix_to_mask(prefix, remain, o1, o2, o3, o4) {
        if (prefix !~ /^[0-9]+$/) return ""
        prefix += 0
        if (prefix < 0 || prefix > 32) return ""

        remain = prefix
        o1 = octet_from_bits(remain); remain -= 8; if (remain < 0) remain = 0
        o2 = octet_from_bits(remain); remain -= 8; if (remain < 0) remain = 0
        o3 = octet_from_bits(remain); remain -= 8; if (remain < 0) remain = 0
        o4 = octet_from_bits(remain)

        return o1 "." o2 "." o3 "." o4
      }

      function skip_network(ip, a) {
        split(ip, a, ".")

        # Do not push non-public IPv4 networks to ocserv clients.
        if (a[1] == 0) return 1
        if (a[1] == 10) return 1
        if (a[1] == 100 && a[2] >= 64 && a[2] <= 127) return 1
        if (a[1] == 127) return 1
        if (a[1] == 169 && a[2] == 254) return 1
        if (a[1] == 172 && a[2] >= 16 && a[2] <= 31) return 1
        if (a[1] == 192 && a[2] == 0 && a[3] == 0) return 1
        if (a[1] == 192 && a[2] == 0 && a[3] == 2) return 1
        if (a[1] == 192 && a[2] == 168) return 1
        if (a[1] == 198 && (a[2] == 18 || a[2] == 19)) return 1
        if (a[1] == 198 && a[2] == 51 && a[3] == 100) return 1
        if (a[1] == 203 && a[2] == 0 && a[3] == 113) return 1
        if (a[1] >= 224) return 1

        return 0
      }

      {
        token = $0
        ip = token
        suffix = ""
        mask = ""

        if (index(token, "/") > 0) {
          split(token, p, "/")
          ip = p[1]
          suffix = p[2]
        }

        if (!valid_ip(ip)) next
        if (skip_network(ip)) next

        if (suffix == "") {
          mask = "255.255.255.255"
        } else if (suffix ~ /^[0-9]+$/) {
          mask = prefix_to_mask(suffix)
        } else if (valid_ip(suffix)) {
          mask = suffix
        } else {
          next
        }

        if (mask == "") next
        print ip "/" mask
      }
    ' \
    | sort -u
}

normalize_routes "${RAW_INPUT}" > "${NORMALIZED}"
normalize_routes "${RAW_EXCLUDE}" > "${EXCLUDE_NORMALIZED}"

if [ -s "${EXCLUDE_NORMALIZED}" ]; then
  grep -vxF -f "${EXCLUDE_NORMALIZED}" "${NORMALIZED}" > "${FILTERED}" || true
else
  cp "${NORMALIZED}" "${FILTERED}"
fi

if [ "${MAX_ROUTES}" != "0" ]; then
  case "${MAX_ROUTES}" in
    ''|*[!0-9]*)
      echo "ERROR: MAX_ROUTES must be a positive integer or 0 for unlimited" >&2
      exit 1
      ;;
  esac

  if [ "${MAX_ROUTES}" -lt 1 ]; then
    echo "ERROR: MAX_ROUTES must be a positive integer or 0 for unlimited" >&2
    exit 1
  fi

  head -n "${MAX_ROUTES}" "${FILTERED}" > "${LIMITED}"
  mv "${LIMITED}" "${FILTERED}"
fi

ROUTE_COUNT="$(grep -c '.' "${FILTERED}" || true)"

if [ "${ROUTE_COUNT}" -lt "${MIN_ROUTES}" ]; then
  echo "ERROR: generated only ${ROUTE_COUNT} routes, expected at least ${MIN_ROUTES}" >&2
  exit 1
fi

{
  echo "# Managed automatically by /usr/local/sbin/update-ocserv-bypass-ru.sh"
  echo "# Do not edit this file by hand."
  echo "#"
  echo "# Group: ${GROUP_NAME}"
  echo "# Local include: ${LOCAL_INCLUDE}"
  echo "# Local exclude: ${LOCAL_EXCLUDE}"
  echo "# MAX_ROUTES: ${MAX_ROUTES}"
  echo "# ROUTE_SOURCE_MODE: ${ROUTE_SOURCE_MODE}"
  echo "# Generated at: $(date -u +%F\ %T) UTC"
  echo
  echo "route = default"
  echo "tunnel-all-dns = true"
  echo "dns = 1.1.1.1"
  echo "dns = 8.8.8.8"
  echo

  while IFS= read -r route; do
    [ -n "${route}" ] || continue
    printf 'no-route = %s\n' "${route}"
  done < "${FILTERED}"
} > "${NEW_GROUP_FILE}"

if [ ! -s "${NEW_GROUP_FILE}" ]; then
  echo "ERROR: generated group config is empty" >&2
  exit 1
fi

if [ -f "${GROUP_FILE}" ]; then
  cp -a "${GROUP_FILE}" "${BACKUP_DIR}/${GROUP_NAME}.$(date +%F-%H%M%S)"
fi

install -m 0640 -o root -g root "${NEW_GROUP_FILE}" "${GROUP_FILE}"
ln -sfn "${GROUP_FILE}" "${DEFAULT_GROUP_FILE}"

ocserv -t -c "${OCSERV_CONF}"

if systemctl reload ocserv 2>/dev/null; then
  echo "ocserv reloaded"
else
  systemctl restart ocserv
  echo "ocserv restarted"
fi

cp -a "${GROUP_FILE}" "${STATE_DIR}/last-${GROUP_NAME}.conf"
cp -a "${FILTERED}" "${STATE_DIR}/last-normalized-routes.txt"

printf 'OK: %s updated\n' "${GROUP_FILE}"
printf 'Routes count: %s\n' "${ROUTE_COUNT}"
UPDATER_SCRIPT

  chmod 0755 "${UPDATER}"
  log "installed ${UPDATER}"
}

migrate_existing_users() {
  if [ ! -f "${OCPASSWD}" ]; then
    install -m 0600 -o root -g root /dev/null "${OCPASSWD}"
    log "created empty ${OCPASSWD}"
    return
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  awk -F: -v group_name="${GROUP_NAME}" '
    BEGIN { OFS = ":" }
    NF >= 3 { $2 = group_name }
    { print }
  ' "${OCPASSWD}" > "${tmp_file}"

  install -m 0600 -o root -g root "${tmp_file}" "${OCPASSWD}"
  rm -f "${tmp_file}"
  log "migrated existing users to group ${GROUP_NAME}"
}

install_cron() {
  mkdir -p "$(dirname "${CRON_FILE}")"

  cat > "${CRON_FILE}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAX_ROUTES=${DEFAULT_MAX_ROUTES}
ROUTE_SOURCE_MODE=${DEFAULT_ROUTE_SOURCE_MODE}

17 4 * * * root ${UPDATER} >> ${LOG_FILE} 2>&1
EOF

  chmod 0644 "${CRON_FILE}"
  log "installed cron job: ${CRON_FILE}"
}

main() {
  local mode="${1:-apply}"

  require_root "$@"

  mkdir -p /run/lock
  exec 8>"${LOCK_FILE}"
  flock -n 8 || die "another route.sh instance is already running"

  case "${mode}" in
    apply)
      ;;
    --rescue|rescue)
      shift || true
      rescue_connection "$@"
      return
      ;;
    --rollback|rollback)
      shift || true
      rollback_route_layer "$@"
      return
      ;;
    *)
      die "unknown mode: $1. Use: $0 [apply|--rescue|--rollback]"
      ;;
  esac

  require_command awk
  require_command curl
  require_command flock
  require_command grep
  require_command install
  require_command ocserv
  require_command sort
  require_command systemctl

  log "creating backups"
  backup_file "${OCSERV_CONF}"
  backup_file "${OCPASSWD}"

  log "creating directories and override files"
  mkdir -p "${GROUP_DIR}" "${DEFAULTS_DIR}" "${STATE_DIR}" /var/log
  touch "${LOCAL_INCLUDE}" "${LOCAL_EXCLUDE}" "${LOG_FILE}"
  chmod 0644 "${LOCAL_INCLUDE}" "${LOCAL_EXCLUDE}" "${LOG_FILE}"

  configure_ocserv_conf
  install_updater
  migrate_existing_users
  install_cron

  log "generating initial ${GROUP_NAME} route config"
  MAX_ROUTES="${DEFAULT_MAX_ROUTES}" ROUTE_SOURCE_MODE="${DEFAULT_ROUTE_SOURCE_MODE}" "${UPDATER}" >> "${LOG_FILE}" 2>&1

  log "done"
  log "new users must be created with: ocpasswd -c ${OCPASSWD} -g ${GROUP_NAME} USERNAME"
}

main "$@"
