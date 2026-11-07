#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

INSTALL_DIR="/opt/openvpnbuilder"
STATE_DIR="/etc/openvpnbuilder"
BIN_PATH="/usr/local/bin/openvpnbuilder"
MANAGER_PATH="${INSTALL_DIR}/openvpnbuilder.sh"
EASYRSA_DIR="${STATE_DIR}/easy-rsa"
CLIENT_DIR="${STATE_DIR}/clients"
ZIP_DIR="${STATE_DIR}/zips"

mkdir -p "$INSTALL_DIR" "$STATE_DIR" "$CLIENT_DIR" "$ZIP_DIR"

# ── Dependencies ─────────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y \
  openvpn easy-rsa curl openssl ufw zip unzip \
  iptables iproute2 ca-certificates python3 resolvconf

# ── EasyRSA PKI bootstrap (only once) ────────────────────────────────────────
if [[ ! -f "${EASYRSA_DIR}/pki/ca.crt" ]]; then
  echo "[INFO] Bootstrapping PKI with EasyRSA..."
  make-cadir "$EASYRSA_DIR"
  cd "$EASYRSA_DIR"

  cat > vars <<'VARS_EOF'
set_var EASYRSA_REQ_COUNTRY    "US"
set_var EASYRSA_REQ_PROVINCE   "California"
set_var EASYRSA_REQ_CITY       "San Francisco"
set_var EASYRSA_REQ_ORG        "OpenVPN Builder"
set_var EASYRSA_REQ_EMAIL      "admin@openvpnbuilder.local"
set_var EASYRSA_REQ_OU         "VPN"
set_var EASYRSA_ALGO            ec
set_var EASYRSA_CURVE           prime256v1
set_var EASYRSA_CA_EXPIRE       3650
set_var EASYRSA_CERT_EXPIRE     3650
set_var EASYRSA_CERT_RENEW      30
set_var EASYRSA_NS_SUPPORT      "no"
VARS_EOF

  ./easyrsa --batch init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa --batch gen-req server nopass
  ./easyrsa --batch sign-req server server
  # No classic Diffie-Hellman: ECDHE with EC certificates needs no dh.pem.
  # tls-crypt key (also authenticates the control channel; replaces tls-auth).
  openvpn --genkey secret "${EASYRSA_DIR}/pki/ta.key"
  # Empty CRL so crl-verify is live from install time, not only after the
  # first revocation (see revoke_client in the manager script).
  ./easyrsa --batch gen-crl
  mkdir -p /etc/openvpn/server
  cp "${EASYRSA_DIR}/pki/crl.pem" /etc/openvpn/server/crl.pem

  cd - >/dev/null
  echo "[OK]  PKI ready"
fi

# ── Detect external interface ─────────────────────────────────────────────────
EXT_IF="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)"

# ── OpenVPN server config — DNS-leak hardened ─────────────────────────────────
mkdir -p /var/log/openvpn

cat > /etc/openvpn/server/server.conf <<SCONF
port 1194
proto udp
dev tun

ca   ${EASYRSA_DIR}/pki/ca.crt
cert ${EASYRSA_DIR}/pki/issued/server.crt
key  ${EASYRSA_DIR}/pki/private/server.key
tls-crypt ${EASYRSA_DIR}/pki/ta.key
crl-verify /etc/openvpn/server/crl.pem

server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"
push "block-outside-dns"

push "route 157.240.0.0 255.255.0.0"
push "route 31.13.24.0 255.255.248.0"
push "route 31.13.64.0 255.255.192.0"
push "route 66.220.144.0 255.255.240.0"
push "route 69.63.176.0 255.255.240.0"
push "route 69.171.224.0 255.255.224.0"
push "route 74.119.76.0 255.255.252.0"
push "route 103.4.96.0 255.255.252.0"
push "route 129.134.0.0 255.255.0.0"
push "route 163.70.128.0 255.255.128.0"
push "route 185.89.216.0 255.255.252.0"
push "route 204.15.20.0 255.255.252.0"

push "tun-ipv6"
push "route-ipv6 2000::/3"
push "ifconfig-ipv6 fd42:42:42::1/112 fd42:42:42::2"

keepalive 10 120
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384
ncp-ciphers AES-256-GCM:AES-256-CBC

comp-lzo no
user nobody
group nogroup
persist-key
persist-tun

status  /var/log/openvpn/openvpn-status.log
log     /var/log/openvpn/openvpn.log
verb 3
SCONF

# ── IP forwarding + NAT ───────────────────────────────────────────────────────
echo 1 > /proc/sys/net/ipv4/ip_forward
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || \
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true

iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$EXT_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$EXT_IF" -j MASQUERADE

iptables -I FORWARD -i tun0 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -i tun0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true

if command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 || true
fi

ufw allow 1194/udp >/dev/null 2>&1 || true
ufw allow OpenSSH  >/dev/null 2>&1 || true

systemctl enable openvpn-server@server >/dev/null 2>&1 || true
systemctl restart openvpn-server@server || true

# ── Manager script ────────────────────────────────────────────────────────────
cat > "$MANAGER_PATH" <<'MANAGER_EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/etc/openvpnbuilder"
EASYRSA_DIR="${STATE_DIR}/easy-rsa"
CLIENT_DIR="${STATE_DIR}/clients"
ZIP_DIR="${STATE_DIR}/zips"
DB_FILE="${STATE_DIR}/clients.db"
PROJECT_NAME="OpenVPN Builder"
PROJECT_REPO="https://github.com/harindujayakody/openvpn-builder"
PROJECT_AUTHOR="Harindu Jayakody"

mkdir -p "$CLIENT_DIR" "$ZIP_DIR"
touch "$DB_FILE"

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
DIM="\033[2m"
BOLD="\033[1m"
RESET="\033[0m"

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Please run with sudo: sudo openvpnbuilder${RESET}"
    exit 1
  fi
}

line()  { printf '%*s\n' "${COLUMNS:-70}" '' | tr ' ' '─'; }
ok()    { echo -e "${GREEN}[OK]${RESET}   $*"; }
info()  { echo -e "${BLUE}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail()  { echo -e "${RED}[ERR]${RESET}  $*"; }
pause() { echo; read -rp "Press Enter to continue..." _; }

title() {
  clear
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}${BOLD}║                    OPENVPN BUILDER                          ║${RESET}"
  echo -e "${CYAN}${BOLD}║            Bulk Client Creator & Manager                    ║${RESET}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo
  echo -e "${DIM}GitHub: ${PROJECT_REPO}${RESET}"
  echo -e "${DIM}Created by: ${PROJECT_AUTHOR}${RESET}"
  echo
}

get_public_ip() {
  local ip
  ip="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  echo "$ip"
}

count_clients() { grep -c . "$DB_FILE" 2>/dev/null || true; }

client_exists() {
  grep -q "^${1}:" "$DB_FILE" 2>/dev/null || false
}

pick_unique_name() {
  local n
  while true; do
    n="client_$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
    client_exists "$n" || { echo "$n"; return; }
  done
}

# ── Generate one signed .ovpn ─────────────────────────────────────────────────
generate_ovpn() {
  local name="$1" pub_ip="$2"
  local ovpn_path="${CLIENT_DIR}/${name}.ovpn"

  cd "$EASYRSA_DIR"
  ./easyrsa --batch gen-req  "$name" nopass 2>/dev/null
  ./easyrsa --batch sign-req client "$name" 2>/dev/null
  cd - >/dev/null

  local ca ta cert key
  ca="$(cat "${EASYRSA_DIR}/pki/ca.crt")"
  ta="$(cat "${EASYRSA_DIR}/pki/ta.key")"
  cert="$(openssl x509 -in "${EASYRSA_DIR}/pki/issued/${name}.crt" 2>/dev/null)"
  key="$(cat "${EASYRSA_DIR}/pki/private/${name}.key")"

  cat > "$ovpn_path" <<OVPN
client
dev tun
proto udp
remote ${pub_ip} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384
block-outside-dns
dhcp-option DNS 1.1.1.1
dhcp-option DNS 1.0.0.1
redirect-gateway def1 bypass-dhcp
tun-ipv6
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
comp-lzo no
verb 3
<ca>
${ca}
</ca>
<cert>
${cert}
</cert>
<key>
${key}
</key>
<tls-crypt>
${ta}
</tls-crypt>
OVPN

  echo "$ovpn_path"
}

# ── Deliver a client ZIP securely (Fixes #1) ─────────────────────────────────
# The old public-HTTP download server ran `python3 -m http.server --bind
# 0.0.0.0` and printed a public http:// link, serving a ZIP that contains a
# client's PRIVATE KEY over unauthenticated plain HTTP to anyone who found
# the port. That path is removed entirely. Delivery is now:
#   1. scp/SFTP over SSH (recommended), or
#   2. an opt-in, localhost-only (127.0.0.1) temporary server that the user
#      reaches through an SSH tunnel — never bound to a public interface,
#      never advertised as a public link.
deliver_zip() {
  local zip_path="$1"
  local pub_ip filename
  pub_ip="$(get_public_ip)"
  filename="$(basename "$zip_path")"

  echo
  echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${GREEN}${BOLD}  ║                  📦  CLIENT ZIP READY                       ║${RESET}"
  echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo
  echo -e "  ${BOLD}File    :${RESET} ${zip_path}"
  echo
  echo -e "  ${BOLD}Download over SSH (recommended):${RESET}"
  echo -e "  ${DIM}scp root@${pub_ip}:${zip_path} .${RESET}"
  echo
  echo -e "  ${DIM}This ZIP contains a client private key. It is never served${RESET}"
  echo -e "  ${DIM}over plain HTTP. If you cannot use scp, you may start a${RESET}"
  echo -e "  ${DIM}localhost-only server and reach it through an SSH tunnel:${RESET}"
  echo -e "  ${DIM}  ssh -L 8900:localhost:8900 root@${pub_ip}${RESET}"
  echo -e "  ${DIM}then open http://localhost:8900/${filename} on your machine.${RESET}"
  echo

  read -rp "  Start a localhost-only (127.0.0.1) server for 120s? [y/N]: " ans
  case "$ans" in
    y|Y)
      local port=8900 server_pid
      cd "$(dirname "$zip_path")"
      python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
      server_pid=$!
      cd - >/dev/null
      echo
      echo -e "  ${YELLOW}Localhost-only server running (127.0.0.1:${port}) — reachable only via SSH tunnel.${RESET}"
      echo -e "  ${DIM}It closes automatically in 120 seconds. Press Ctrl+C to close early.${RESET}"
      trap "kill $server_pid 2>/dev/null; echo; ok 'Local download server closed.'; trap - INT TERM; return" INT TERM
      local i
      for ((i=120; i>0; i--)); do
        kill -0 "$server_pid" 2>/dev/null || break
        printf "\r  ${DIM}⏱  Closing in %3d seconds... (Ctrl+C to close now)${RESET}   " "$i"
        sleep 1
      done
      kill "$server_pid" 2>/dev/null || true
      trap - INT TERM
      echo
      echo
      ok "Local download server closed."
      ;;
    *) info "Skipped local server. ZIP kept at: ${zip_path}" ;;
  esac
  echo -e "  ${DIM}ZIP saved permanently at: ${zip_path}${RESET}"
}

# ── Create single client ──────────────────────────────────────────────────────
create_one() {
  local pub_ip name ovpn_path zip_path
  pub_ip="$(get_public_ip)"
  [[ -z "$pub_ip" ]] && { fail "No public IPv4 detected."; return; }

  read -rp "Client name (blank = random): " name
  name="${name:-$(pick_unique_name)}"
  name="$(echo "$name" | tr -dc 'a-zA-Z0-9_-' | head -c 32)"
  [[ -z "$name" ]] && { fail "Invalid name."; return; }

  if client_exists "$name"; then
    fail "Client '${name}' already exists."; return
  fi

  info "Generating certificate for '${name}'..."
  ovpn_path="$(generate_ovpn "$name" "$pub_ip")"

  zip_path="${ZIP_DIR}/${name}.zip"
  zip -j "$zip_path" "$ovpn_path" >/dev/null
  echo "${name}:${pub_ip}:$(date +%Y-%m-%d)" >> "$DB_FILE"

  ok "Client '${name}' created"
  deliver_zip "$zip_path"
}

# ── Bulk create ───────────────────────────────────────────────────────────────
create_bulk() {
  local pub_ip count prefix
  pub_ip="$(get_public_ip)"
  [[ -z "$pub_ip" ]] && { fail "No public IPv4 detected."; return; }

  read -rp "How many clients (1-200): " count
  if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 1 || count > 200 )); then
    fail "Count must be 1-200."; return
  fi

  read -rp "Name prefix (blank = 'client'): " prefix
  prefix="${prefix:-client}"
  prefix="$(echo "$prefix" | tr -dc 'a-zA-Z0-9_-' | head -c 20)"
  [[ -z "$prefix" ]] && prefix="client"

  # build unique name list
  local names=() i=1
  while (( ${#names[@]} < count )); do
    local candidate="${prefix}_$(printf '%03d' $i)"
    client_exists "$candidate" || names+=("$candidate")
    ((i++))
  done

  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local all_zip="${ZIP_DIR}/bulk_${prefix}_${timestamp}.zip"
  local ovpn_files=()

  echo
  info "Generating ${count} clients — prefix '${prefix}'..."
  echo

  for name in "${names[@]}"; do
    printf "  ${BLUE}→${RESET} %-32s" "$name"
    local ovpn_path
    ovpn_path="$(generate_ovpn "$name" "$pub_ip")"
    ovpn_files+=("$ovpn_path")
    echo "${name}:${pub_ip}:$(date +%Y-%m-%d)" >> "$DB_FILE"
    echo -e " ${GREEN}✓${RESET}"
  done

  echo
  info "Packing ${count} .ovpn files into ZIP..."

  # zip all ovpn files into single archive
  zip -j "$all_zip" "${ovpn_files[@]}" >/dev/null

  echo
  ok "All ${count} clients packed into: $(basename "$all_zip")"

  # auto serve with download link — no prompts
  deliver_zip "$all_zip"
}

# ── List clients ──────────────────────────────────────────────────────────────
list_clients() {
  local total
  total="$(count_clients)"
  echo
  echo -e "${MAGENTA}${BOLD}OpenVPN Clients${RESET}"
  line
  if [[ "$total" -eq 0 ]]; then warn "No clients yet."; return; fi
  local i=1
  while IFS=: read -r name ip date; do
    echo -e "  ${BOLD}${i})${RESET} ${GREEN}${name}${RESET}  ${DIM}${ip} | ${date}${RESET}"
    ((i++))
  done < "$DB_FILE"
  echo
  ok "Total: ${total}"
}

# ── Re-download any client zip ────────────────────────────────────────────────
download_existing() {
  local total
  total="$(count_clients)"
  if [[ "$total" -eq 0 ]]; then warn "No clients yet."; return; fi

  list_clients
  echo
  read -rp "Enter client number (0 to cancel): " sel
  [[ "$sel" == "0" ]] && return

  if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > total )); then
    fail "Invalid selection."; return
  fi

  local name
  name="$(sed -n "${sel}p" "$DB_FILE" | cut -d: -f1)"
  local zip_path="${ZIP_DIR}/${name}.zip"

  if [[ ! -f "$zip_path" ]]; then
    local ovpn_path="${CLIENT_DIR}/${name}.ovpn"
    [[ ! -f "$ovpn_path" ]] && { fail ".ovpn not found for ${name}."; return; }
    zip -j "$zip_path" "$ovpn_path" >/dev/null
  fi

  deliver_zip "$zip_path"
}

# ── Revoke client ─────────────────────────────────────────────────────────────
revoke_client() {
  local total
  total="$(count_clients)"
  if [[ "$total" -eq 0 ]]; then warn "No clients to revoke."; return; fi

  list_clients
  echo
  read -rp "Enter client number to revoke (0 to cancel): " sel
  [[ "$sel" == "0" ]] && return

  if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > total )); then
    fail "Invalid selection."; return
  fi

  local name
  name="$(sed -n "${sel}p" "$DB_FILE" | cut -d: -f1)"

  cd "$EASYRSA_DIR"
  ./easyrsa --batch revoke "$name" 2>/dev/null || true
  ./easyrsa --batch gen-crl          2>/dev/null || true
  cp pki/crl.pem /etc/openvpn/server/crl.pem 2>/dev/null || true
  cd - >/dev/null

  rm -f "${CLIENT_DIR}/${name}.ovpn" "${ZIP_DIR}/${name}.zip"
  sed -i "/^${name}:/d" "$DB_FILE"

  grep -q "crl-verify" /etc/openvpn/server/server.conf || \
    echo "crl-verify /etc/openvpn/server/crl.pem" >> /etc/openvpn/server/server.conf
  systemctl restart openvpn-server@server || true
  ok "Client '${name}' revoked."
}

# ── Server status ─────────────────────────────────────────────────────────────
show_status() {
  echo
  echo -e "${CYAN}${BOLD}OpenVPN Server Status${RESET}"
  line
  systemctl status openvpn-server@server --no-pager -l 2>/dev/null || true
  echo
  if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
    echo -e "${BOLD}Connected clients:${RESET}"
    grep "^CLIENT_LIST" /var/log/openvpn/openvpn-status.log 2>/dev/null || echo "  None connected"
  fi
}

show_summary() {
  local total pub_ip
  total="$(count_clients)"
  pub_ip="$(get_public_ip)"
  echo
  line
  echo -e "${BOLD}Project       :${RESET} ${PROJECT_NAME}"
  echo -e "${BOLD}Public IPv4   :${RESET} ${pub_ip:-N/A}"
  echo -e "${BOLD}Total Clients :${RESET} ${total}"
  echo -e "${BOLD}Clients dir   :${RESET} ${CLIENT_DIR}/"
  echo -e "${BOLD}ZIPs dir      :${RESET} ${ZIP_DIR}/"
  echo -e "${BOLD}Command       :${RESET} sudo openvpnbuilder"
  echo -e "${BOLD}GitHub        :${RESET} ${PROJECT_REPO}"
  line
  echo
}

menu() {
  title
  show_summary
  echo -e "${BOLD}1)${RESET} Create Single Client       ${DIM}(secure copy)${RESET}"
  echo -e "${BOLD}2)${RESET} Create Bulk Clients        ${DIM}(auto ZIP + secure copy)${RESET}"
  echo -e "${BOLD}3)${RESET} List All Clients"
  echo -e "${BOLD}4)${RESET} Re-Download a Client ZIP"
  echo -e "${BOLD}5)${RESET} Revoke / Delete Client"
  echo -e "${BOLD}6)${RESET} Server Status"
  echo -e "${BOLD}7)${RESET} Exit"
  echo
}

main() {
  require_root
  while true; do
    menu
    read -rp "Select option [1-7]: " choice
    case "$choice" in
      1) create_one;        pause ;;
      2) create_bulk;       pause ;;
      3) list_clients;      pause ;;
      4) download_existing; pause ;;
      5) revoke_client;     pause ;;
      6) show_status;       pause ;;
      7) exit 0 ;;
      *) fail "Invalid option"; sleep 1 ;;
    esac
  done
}

main
MANAGER_EOF

chmod +x "$MANAGER_PATH"
ln -sf "$MANAGER_PATH" "$BIN_PATH"

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    OPENVPN BUILDER                          ║"
echo "║            Bulk Client Creator & Manager                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "PKI       : ${EASYRSA_DIR}/pki/"
echo "Clients   : ${CLIENT_DIR}/"
echo "ZIPs      : ${ZIP_DIR}/"
echo "Command   : sudo openvpnbuilder"
echo "GitHub    : https://github.com/harindujayakody/openvpn-builder"
echo
echo "Run: sudo openvpnbuilder"
echo
