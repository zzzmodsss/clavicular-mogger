#!/usr/bin/env bash
set -Eeuo pipefail

# Xray REALITY VLESS auto installer / manager
# Supports: install, reconfigure, client links, status, logs, uninstall
# Run as root: bash xray_reality_auto_installer.sh

APP_NAME="nginx-stream"
BIN_PATH="/usr/local/bin/${APP_NAME}"
CONFIG_DIR="/etc/nginx-stream"
CONFIG_FILE="${CONFIG_DIR}/stream.json"
STATE_FILE="${CONFIG_DIR}/state.env"
LINKS_FILE="${CONFIG_DIR}/client-links.txt"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
GEODATA_DIR="/usr/local/bin"
DEFAULT_PATH="/xhttp-main"
DEFAULT_GRPC_SERVICE="xraygrpc"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[-]${NC} $*" >&2; }
info() { echo -e "${BLUE}[*]${NC} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запусти от root: sudo bash $0"
    exit 1
  fi
}

install_deps() {
  log "Ставлю зависимости"
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y curl jq openssl ca-certificates ufw iproute2 dnsutils iperf3 unzip wget
}

install_xray() {
  log "Скачиваю Xray и маскирую бинарь как ${APP_NAME}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) err "Неизвестная архитектура: ${arch}. Нужен x86_64/amd64 или arm64/aarch64"; exit 1 ;;
  esac
  curl -fL "https://github.com/XTLS/Xray-core/releases/latest/download/${asset}" -o "${tmpdir}/xray.zip"
  unzip -o "${tmpdir}/xray.zip" xray -d "${tmpdir}"
  install -m 0755 "${tmpdir}/xray" "${BIN_PATH}"
  "${BIN_PATH}" version | head -n 1 || true
}

generate_keys() {
  UUID="${UUID:-$(${BIN_PATH} uuid)}"
  keypair="$(${BIN_PATH} x25519)"
  PRIVATE_KEY="${PRIVATE_KEY:-$(echo "${keypair}" | awk -F': ' '/Private key/ {print $2}') }"
  PUBLIC_KEY="${PUBLIC_KEY:-$(echo "${keypair}" | awk -F': ' '/Public key/ {print $2}') }"
  PRIVATE_KEY="$(echo "${PRIVATE_KEY}" | xargs)"
  PUBLIC_KEY="$(echo "${PUBLIC_KEY}" | xargs)"
  SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"
}

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

save_state() {
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"
  umask 077
  cat >"${STATE_FILE}" <<EOF
SERVER_IP='${SERVER_IP}'
PORT='${PORT}'
SNI='${SNI}'
DEST='${DEST}'
NETWORK='${NETWORK}'
PATH_VALUE='${PATH_VALUE}'
GRPC_SERVICE='${GRPC_SERVICE}'
UUID='${UUID}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
SS_ENABLED='${SS_ENABLED}'
SS_ADDRESS='${SS_ADDRESS}'
SS_PORT='${SS_PORT}'
SS_METHOD='${SS_METHOD}'
SS_PASSWORD='${SS_PASSWORD}'
TG_ENABLED='${TG_ENABLED}'
EOF
}

public_ip() {
  curl -4fsS https://api.ipify.org || hostname -I | awk '{print $1}'
}

ask() {
  local var="$1"
  local prompt="$2"
  local def="${3:-}"
  local val=""
  if [[ -n "${def}" ]]; then
    read -r -p "${prompt} [${def}]: " val || true
    printf -v "${var}" '%s' "${val:-$def}"
  else
    read -r -p "${prompt}: " val || true
    printf -v "${var}" '%s' "${val}"
  fi
}

ask_secret() {
  local var="$1"
  local prompt="$2"
  local def="${3:-}"
  local val=""
  if [[ -n "${def}" ]]; then
    read -r -s -p "${prompt} [оставить текущее]: " val || true
    echo
    printf -v "${var}" '%s' "${val:-$def}"
  else
    read -r -s -p "${prompt}: " val || true
    echo
    printf -v "${var}" '%s' "${val}"
  fi
}

choose_network() {
  echo "Выбери transport:"
  echo "1) xhttp  - рекомендовано"
  echo "2) grpc"
  echo "3) ws"
  echo "4) httpupgrade"
  echo "5) tcp/raw"
  local n
  read -r -p "Номер [1]: " n || true
  case "${n:-1}" in
    1) NETWORK="xhttp" ;;
    2) NETWORK="grpc" ;;
    3) NETWORK="ws" ;;
    4) NETWORK="httpupgrade" ;;
    5) NETWORK="tcp" ;;
    *) NETWORK="xhttp" ;;
  esac
}

collect_config() {
  load_state
  SERVER_IP="${SERVER_IP:-$(public_ip)}"
  ask SERVER_IP "Публичный IP/домен сервера для клиентской ссылки" "${SERVER_IP}"
  ask PORT "Порт" "${PORT:-443}"
  ask SNI "SNI / serverName" "${SNI:-api-maps.yandex.ru}"
  ask DEST "REALITY target host:port" "${DEST:-${SNI}:443}"

  old_net="${NETWORK:-xhttp}"
  choose_network
  [[ -z "${NETWORK:-}" ]] && NETWORK="${old_net}"

  ask PATH_VALUE "Path для xhttp/ws/httpupgrade" "${PATH_VALUE:-${DEFAULT_PATH}}"
  ask GRPC_SERVICE "serviceName для grpc" "${GRPC_SERVICE:-${DEFAULT_GRPC_SERVICE}}"

  echo
  echo "Маршрутизация остального трафика:"
  echo "1) Через Shadowsocks upstream"
  echo "2) Напрямую freedom"
  local ss_choice
  read -r -p "Выбор [${SS_ENABLED:-1}]: " ss_choice || true
  ss_choice="${ss_choice:-${SS_ENABLED:-1}}"
  if [[ "${ss_choice}" == "1" || "${ss_choice}" == "yes" || "${ss_choice}" == "true" ]]; then
    SS_ENABLED="1"
    ask SS_ADDRESS "Shadowsocks address" "${SS_ADDRESS:-}"
    ask SS_PORT "Shadowsocks port" "${SS_PORT:-443}"
    ask SS_METHOD "Shadowsocks method" "${SS_METHOD:-chacha20-ietf-poly1305}"
    ask_secret SS_PASSWORD "Shadowsocks password" "${SS_PASSWORD:-}"
  else
    SS_ENABLED="0"
    SS_ADDRESS="${SS_ADDRESS:-}"
    SS_PORT="${SS_PORT:-443}"
    SS_METHOD="${SS_METHOD:-chacha20-ietf-poly1305}"
    SS_PASSWORD="${SS_PASSWORD:-}"
  fi

  read -r -p "Поставить traffic-guard? y/N [${TG_ENABLED:-0}]: " tg || true
  tg="${tg:-${TG_ENABLED:-0}}"
  if [[ "${tg}" =~ ^([yY][eE][sS]|[yY]|1)$ ]]; then TG_ENABLED="1"; else TG_ENABLED="0"; fi

  if [[ -z "${UUID:-}" || -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" || -z "${SHORT_ID:-}" ]]; then
    generate_keys
  fi
}

transport_json() {
  local net_json_name="$1"
  case "${net_json_name}" in
    xhttp)
      jq -n --arg path "${PATH_VALUE}" '{network:"xhttp", settings:{xhttpSettings:{path:$path, mode:"auto"}}}'
      ;;
    grpc)
      jq -n --arg service "${GRPC_SERVICE}" --arg authority "${SNI}" '{network:"grpc", settings:{grpcSettings:{serviceName:$service, authority:$authority, multiMode:false}}}'
      ;;
    ws)
      jq -n --arg path "${PATH_VALUE}" --arg host "${SNI}" '{network:"ws", settings:{wsSettings:{path:$path, headers:{Host:$host}}}}'
      ;;
    httpupgrade)
      jq -n --arg path "${PATH_VALUE}" --arg host "${SNI}" '{network:"httpupgrade", settings:{httpupgradeSettings:{path:$path, host:$host}}}'
      ;;
    tcp|raw)
      jq -n '{network:"raw", settings:{rawSettings:{}}}'
      ;;
    *)
      err "Неизвестный NETWORK=${NETWORK}"
      exit 1
      ;;
  esac
}

write_config() {
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"

  transport="$(transport_json "${NETWORK}")"
  network_for_xray="$(echo "${transport}" | jq -r '.network')"
  settings_obj="$(echo "${transport}" | jq -c '.settings')"
  flow_value=""
  if [[ "${NETWORK}" == "tcp" || "${NETWORK}" == "raw" ]]; then
    flow_value="xtls-rprx-vision"
  fi

  if [[ "${SS_ENABLED}" == "1" ]]; then
    default_outbound="to-shadowsocks"
  else
    default_outbound="direct"
  fi

  jq -n \
    --arg uuid "${UUID}" \
    --arg flow "${flow_value}" \
    --arg port "${PORT}" \
    --arg network "${network_for_xray}" \
    --arg sni "${SNI}" \
    --arg dest "${DEST}" \
    --arg privateKey "${PRIVATE_KEY}" \
    --arg shortId "${SHORT_ID}" \
    --argjson transportSettings "${settings_obj}" \
    --arg ssAddress "${SS_ADDRESS}" \
    --arg ssPort "${SS_PORT}" \
    --arg ssMethod "${SS_METHOD}" \
    --arg ssPassword "${SS_PASSWORD}" \
    --arg defaultOutbound "${default_outbound}" \
    '
    {
      log: {loglevel: "warning"},
      inbounds: [
        {
          tag: "inbound-https",
          listen: "0.0.0.0",
          port: ($port|tonumber),
          protocol: "vless",
          settings: {
            clients: [ if $flow == "" then {id: $uuid} else {id: $uuid, flow: $flow} end ],
            decryption: "none"
          },
          streamSettings: ({
            network: $network,
            security: "reality",
            realitySettings: {
              show: false,
              target: $dest,
              serverNames: [$sni],
              privateKey: $privateKey,
              shortIds: [$shortId]
            }
          } + $transportSettings),
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"]
          }
        }
      ],
      outbounds: [
        {
          tag: "direct",
          protocol: "freedom"
        },
        {
          tag: "to-shadowsocks",
          protocol: "shadowsocks",
          settings: {
            servers: [
              {
                address: $ssAddress,
                port: ($ssPort|tonumber),
                method: $ssMethod,
                password: $ssPassword
              }
            ]
          }
        },
        {
          tag: "drop",
          protocol: "blackhole"
        }
      ],
      routing: {
        domainStrategy: "IPIfNonMatch",
        rules: [
          {
            type: "field",
            inboundTag: ["inbound-https"],
            domain: ["geosite:category-ru", "regexp:.*\\.ru$"],
            outboundTag: "direct"
          },
          {
            type: "field",
            inboundTag: ["inbound-https"],
            ip: ["geoip:ru"],
            outboundTag: "direct"
          },
          {
            type: "field",
            inboundTag: ["inbound-https"],
            outboundTag: $defaultOutbound
          }
        ]
      }
    }
    ' >"${CONFIG_FILE}"

  chmod 600 "${CONFIG_FILE}"
  log "Конфиг записан: ${CONFIG_FILE}"
  "${BIN_PATH}" run -test -c "${CONFIG_FILE}"
}

install_geodata() {
  log "Скачиваю geosite.dat и geoip.dat"
  curl -fL https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat -o "${GEODATA_DIR}/geosite.dat"
  curl -fL https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat -o "${GEODATA_DIR}/geoip.dat"
}

write_service() {
  cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=Nginx Stream Handling Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNPROC=500
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}"
}

configure_firewall() {
  log "Настраиваю ufw"
  ufw allow OpenSSH || true
  ufw allow "${PORT}/tcp" || true
  yes | ufw enable || true
}

install_traffic_guard() {
  if [[ "${TG_ENABLED}" != "1" ]]; then
    warn "traffic-guard пропущен"
    return 0
  fi
  log "Устанавливаю traffic-guard"
  curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | bash
  traffic-guard full \
    -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
    -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/26929c9db71443a18c4369299ba60673a792c2ac/public/government_networks.list \
    -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list \
    --enable-logging || warn "traffic-guard вернул ошибку, Xray всё равно установлен"
}

urlenc() {
  jq -rn --arg v "$1" '$v|@uri'
}

client_link() {
  load_state
  local type="${NETWORK}"
  local flow=""
  local extra=""
  local enc_path enc_service enc_sni enc_sid enc_pb enc_host name
  enc_sni="$(urlenc "${SNI}")"
  enc_sid="$(urlenc "${SHORT_ID}")"
  enc_pb="$(urlenc "${PUBLIC_KEY}")"
  enc_host="$(urlenc "${SERVER_IP}")"
  name="$(urlenc "${APP_NAME}-${NETWORK}-${SERVER_IP}")"

  case "${NETWORK}" in
    xhttp)
      enc_path="$(urlenc "${PATH_VALUE}")"
      extra="&type=xhttp&path=${enc_path}&mode=auto"
      ;;
    grpc)
      enc_service="$(urlenc "${GRPC_SERVICE}")"
      extra="&type=grpc&serviceName=${enc_service}&authority=${enc_sni}"
      ;;
    ws)
      enc_path="$(urlenc "${PATH_VALUE}")"
      extra="&type=ws&path=${enc_path}&host=${enc_sni}"
      ;;
    httpupgrade)
      enc_path="$(urlenc "${PATH_VALUE}")"
      extra="&type=httpupgrade&path=${enc_path}&host=${enc_sni}"
      ;;
    tcp|raw)
      type="tcp"
      flow="&flow=xtls-rprx-vision"
      extra="&type=tcp&headerType=none${flow}"
      ;;
  esac

  echo "vless://${UUID}@${enc_host}:${PORT}?encryption=none&security=reality&sni=${enc_sni}&fp=chrome&pbk=${enc_pb}&sid=${enc_sid}${extra}#${name}"
}

write_links() {
  mkdir -p "${CONFIG_DIR}"
  client_link | tee "${LINKS_FILE}"
  chmod 600 "${LINKS_FILE}"
  log "Клиентская ссылка сохранена: ${LINKS_FILE}"
}

show_summary() {
  load_state
  echo
  log "Готово"
  echo "IP/host: ${SERVER_IP}"
  echo "Port: ${PORT}"
  echo "SNI: ${SNI}"
  echo "Transport: ${NETWORK}"
  echo "UUID: ${UUID}"
  echo "Public key: ${PUBLIC_KEY}"
  echo "Short ID: ${SHORT_ID}"
  echo
  echo "Клиентская ссылка:"
  cat "${LINKS_FILE}" 2>/dev/null || client_link
  echo
  echo "Команды:"
  echo "  systemctl status ${APP_NAME} --no-pager -l"
  echo "  journalctl -u ${APP_NAME} -f"
  echo "  bash $0 menu"
}

install_all() {
  need_root
  install_deps
  install_xray
  collect_config
  save_state
  write_config
  install_geodata
  write_service
  configure_firewall
  install_traffic_guard
  write_links
  show_summary
}

reconfigure() {
  need_root
  if [[ ! -x "${BIN_PATH}" ]]; then
    err "Xray ещё не установлен. Сначала выбери install."
    exit 1
  fi
  collect_config
  save_state
  write_config
  configure_firewall
  systemctl restart "${APP_NAME}"
  write_links
  show_summary
}

status() {
  systemctl status "${APP_NAME}" --no-pager -l || true
}

logs() {
  journalctl -u "${APP_NAME}" -n 100 --no-pager || true
}

uninstall_all() {
  need_root
  warn "Удаляю сервис и конфиги ${APP_NAME}"
  systemctl disable --now "${APP_NAME}" || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload
  rm -rf "${CONFIG_DIR}"
  rm -f "${BIN_PATH}"
  log "Удалено. ufw/geodata/traffic-guard не трогал."
}

menu() {
  while true; do
    echo
    echo "=== ${APP_NAME} manager ==="
    echo "1) Установить / переустановить"
    echo "2) Изменить SNI/порт/transport/маршрутизацию"
    echo "3) Показать клиентскую ссылку"
    echo "4) Статус"
    echo "5) Логи"
    echo "6) Удалить"
    echo "0) Выход"
    read -r -p "Выбор: " choice || true
    case "${choice}" in
      1) install_all ;;
      2) reconfigure ;;
      3) write_links ;;
      4) status ;;
      5) logs ;;
      6) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Непонятный выбор" ;;
    esac
  done
}

case "${1:-menu}" in
  install) install_all ;;
  reconfigure|change) reconfigure ;;
  link|links) write_links ;;
  status) status ;;
  logs) logs ;;
  uninstall) uninstall_all ;;
  menu|*) menu ;;
esac
