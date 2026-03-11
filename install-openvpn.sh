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

# ── Dependencies ────────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y \
  openvpn easy-rsa curl openssl ufw zip unzip \
  iptables iproute2 ca-certificates

# ── EasyRSA PKI bootstrap (only if not already done) ────────────────────────
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
set_var EASYRSA_KEY_SIZE        2048
set_var EASYRSA_ALGO            rsa
set_var EASYRSA_CA_EXPIRE       3650
set_var EASYRSA_CERT_EXPIRE     3650
set_var EASYRSA_CERT_RENEW      30
set_var EASYRSA_NS_SUPPORT      "no"
VARS_EOF

  ./easyrsa --batch init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa --batch gen-req server nopass
  ./easyrsa --batch sign-req server server
  ./easyrsa --batch gen-dh
  openvpn --genkey secret "${EASYRSA_DIR}/pki/ta.key"

  cd - >/dev/null
  echo "[OK]  PKI ready"
fi

# ── OpenVPN server config ────────────────────────────────────────────────────
EXT_IF="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)"

cat > /etc/openvpn/server/server.conf <<SCONF
port 1194
proto udp
dev tun

ca   ${EASYRSA_DIR}/pki/ca.crt
cert ${EASYRSA_DIR}/pki/issued/server.crt
key  ${EASYRSA_DIR}/pki/private/server.key
dh   ${EASYRSA_DIR}/pki/dh.pem
tls-auth ${EASYRSA_DIR}/pki/ta.key 0

server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"

keepalive 10 120
cipher AES-256-CBC
auth SHA256
comp-lzo
user nobody
group nogroup
persist-key
persist-tun

status /var/log/openvpn/openvpn-status.log
log    /var/log/openvpn/openvpn.log
verb 3
SCONF

mkdir -p /var/log/openvpn

# ── IP forwarding & NAT ──────────────────────────────────────────────────────
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf || \
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true

iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$EXT_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$EXT_IF" -j MASQUERADE

# persist iptables rule
if command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 || true
fi

# ── UFW ─────────────────────────────────────────────────────────────────────
ufw allow 1194/udp >/dev/null 2>&1 || true
ufw allow OpenSSH  >/dev/null 2>&1 || true

# ── Enable & start OpenVPN ───────────────────────────────────────────────────
systemctl enable openvpn-server@server >/dev/null 2>&1 || true
systemctl restart openvpn-server@server || true

# ── Write the manager script ─────────────────────────────────────────────────
cat > "$MANAGER_PATH" <<'MANAGER_EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/etc/openvpnbuilder"
EASYRSA_DIR="${STATE_DIR}/easy-rsa"
CLIENT_DIR="${STATE_DIR}/clients"
ZIP_DIR="${STATE_DIR}/zips"
DB_FILE="${STATE_DIR}/clients.db"
PROJECT_NAME="OpenVPN Builder"
PROJECT_REPO="https://github.com/harindujayakody/proxy-builder"
PROJECT_AUTHOR="Harindu Jayakody"

mkdir -p "$CLIENT_DIR" "$ZIP_DIR"
touch "$DB_FILE"

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
CYAN="\033[1;36m"
DIM="\033[2m"
BOLD="\033[1m"
RESET="\033[0m"

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Please run with sudo: sudo openvpnbuilder${RESET}"
    exit 1
  fi
}

line() { printf '%*s\n' "${COLUMNS:-70}" '' | tr ' ' '─'; }

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

ok()   { echo -e "${GREEN}[OK]${RESET}   $*"; }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[ERR]${RESET}  $*"; }

pause() { echo; read -rp "Press Enter to continue..." _; }

get_public_ip() {
  local ip
  ip="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  echo "$ip"
}

count_clients() { grep -c . "$DB_FILE" 2>/dev/null || true; }

client_exists() {
  local name="$1"
  grep -q "^${name}:" "$DB_FILE" 2>/dev/null || false
}

random_name() {
  echo "client_$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
}

pick_unique_name() {
  local n
  while true; do
    n="$(random_name)"
    if ! client_exists "$n"; then echo "$n"; return; fi
  done
}

# ── Generate a single .ovpn file ─────────────────────────────────────────────
generate_ovpn() {
  local name="$1"
  local pub_ip="$2"
  local ovpn_path="${CLIENT_DIR}/${name}.ovpn"

  cd "$EASYRSA_DIR"
  ./easyrsa --batch gen-req "$name" nopass 2>/dev/null
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
cipher AES-256-CBC
auth SHA256
comp-lzo
verb 3
key-direction 1

<ca>
${ca}
</ca>
<cert>
${cert}
</cert>
<key>
${key}
</key>
<tls-auth>
${ta}
</tls-auth>
OVPN

  echo "$ovpn_path"
}

# ── Create single client ──────────────────────────────────────────────────────
create_one() {
  local pub_ip name ovpn_path zip_path
  pub_ip="$(get_public_ip)"
  [[ -z "$pub_ip" ]] && { fail "No public IPv4 detected."; return; }

  read -rp "Client name (leave blank for random): " name
  name="${name:-$(pick_unique_name)}"

  # sanitize
  name="$(echo "$name" | tr -dc 'a-zA-Z0-9_-' | head -c 32)"
  [[ -z "$name" ]] && { fail "Invalid name."; return; }

  if client_exists "$name"; then
    fail "Client '${name}' already exists."
    return
  fi

  info "Generating certificate for '${name}'..."
  ovpn_path="$(generate_ovpn "$name" "$pub_ip")"

  zip_path="${ZIP_DIR}/${name}.zip"
  zip -j "$zip_path" "$ovpn_path" >/dev/null

  echo "${name}:${pub_ip}:$(date +%Y-%m-%d)" >> "$DB_FILE"

  ok "Client created: ${name}"
  echo
  echo -e "${BOLD}  .ovpn file :${RESET} ${ovpn_path}"
  echo -e "${BOLD}  .zip file  :${RESET} ${zip_path}"
  echo
  echo -e "${DIM}  Download:  cat ${zip_path} | base64${RESET}"
}

# ── Bulk create clients ───────────────────────────────────────────────────────
create_bulk() {
  local pub_ip count prefix
  pub_ip="$(get_public_ip)"
  [[ -z "$pub_ip" ]] && { fail "No public IPv4 detected."; return; }

  read -rp "How many clients to create (1-200): " count
  if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 1 || count > 200 )); then
    fail "Count must be between 1 and 200."
    return
  fi

  read -rp "Name prefix (leave blank for 'client'): " prefix
  prefix="${prefix:-client}"
  prefix="$(echo "$prefix" | tr -dc 'a-zA-Z0-9_-' | head -c 20)"
  [[ -z "$prefix" ]] && prefix="client"

  local names=()
  local i=1
  while (( ${#names[@]} < count )); do
    local candidate="${prefix}_$(printf '%03d' $i)"
    if ! client_exists "$candidate"; then
      names+=("$candidate")
    fi
    ((i++))
  done

  echo
  info "Creating ${count} OpenVPN clients with prefix '${prefix}'..."
  echo

  local all_zip="${ZIP_DIR}/bulk_${prefix}_$(date +%Y%m%d_%H%M%S).zip"
  local ovpn_files=()

  for name in "${names[@]}"; do
    info "  → ${name}"
    local ovpn_path
    ovpn_path="$(generate_ovpn "$name" "$pub_ip")"
    ovpn_files+=("$ovpn_path")
    echo "${name}:${pub_ip}:$(date +%Y-%m-%d)" >> "$DB_FILE"
  done

  # zip all ovpn files into one archive
  zip -j "$all_zip" "${ovpn_files[@]}" >/dev/null

  echo
  ok "Created ${count} clients"
  echo
  echo -e "${BOLD}  Individual .ovpn files :${RESET} ${CLIENT_DIR}/"
  echo -e "${BOLD}  Bulk ZIP archive       :${RESET} ${all_zip}"
  echo
  echo -e "${GREEN}${BOLD}  ↓ Download ZIP:${RESET}"
  echo -e "  ${DIM}cat ${all_zip} | base64${RESET}"
  echo
  show_download_link "$all_zip"
}

# ── Show a simple HTTP download server for a zip ─────────────────────────────
show_download_link() {
  local zip_path="$1"
  local pub_ip port
  pub_ip="$(get_public_ip)"
  port="$(shuf -i 8100-8900 -n 1)"

  echo
  echo -e "${CYAN}${BOLD}  ┌─ One-Time Download Server ─────────────────────────────┐${RESET}"
  echo -e "${CYAN}${BOLD}  │${RESET}  Run this on your server to serve the ZIP for 60s:     ${CYAN}${BOLD}│${RESET}"
  echo -e "${CYAN}${BOLD}  │${RESET}                                                        ${CYAN}${BOLD}│${RESET}"
  echo -e "${CYAN}${BOLD}  │${RESET}  ${BOLD}cd $(dirname "$zip_path") && python3 -m http.server ${port}${RESET}  ${CYAN}${BOLD}│${RESET}"
  echo -e "${CYAN}${BOLD}  │${RESET}                                                        ${CYAN}${BOLD}│${RESET}"
  echo -e "${CYAN}${BOLD}  │${RESET}  Then download from your browser or curl:              ${CYAN}${BOLD}│${RESET}"
  echo -e "${CYAN}${BOLD}  │${RESET}  ${GREEN}http://${pub_ip}:${port}/$(basename "$zip_path")${RESET}  ${CYAN}${BOLD}│${RESET}"
  echo -e "${CYAN}${BOLD}  └────────────────────────────────────────────────────────┘${RESET}"
  echo
  read -rp "  Start download server now? (60 second timeout) [y/N]: " yn
  if [[ "${yn,,}" == "y" ]]; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    echo
    ok "Server starting on port ${port}. Press Ctrl+C to stop."
    echo -e "  ${GREEN}Download: http://${pub_ip}:${port}/$(basename "$zip_path")${RESET}"
    echo
    cd "$(dirname "$zip_path")"
    timeout 60 python3 -m http.server "$port" 2>/dev/null || true
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    echo
    ok "Download server stopped."
  fi
}

# ── List clients ──────────────────────────────────────────────────────────────
list_clients() {
  local total
  total="$(count_clients)"
  echo
  echo -e "${MAGENTA}${BOLD}OpenVPN Clients${RESET}"
  line

  if [[ "$total" -eq 0 ]]; then
    warn "No clients created yet."; return
  fi

  local i=1
  while IFS=: read -r name ip date; do
    echo -e "  ${BOLD}${i})${RESET} ${GREEN}${name}${RESET}  ${DIM}(server: ${ip} | created: ${date})${RESET}"
    echo -e "      .ovpn → ${CLIENT_DIR}/${name}.ovpn"
    ((i++))
  done < "$DB_FILE"

  echo
  ok "Total clients: ${total}"
}

# ── Download / zip a single client ───────────────────────────────────────────
download_single() {
  local total
  total="$(count_clients)"

  if [[ "$total" -eq 0 ]]; then warn "No clients created yet."; return; fi

  list_clients
  echo
  read -rp "Enter client number to download (0 to cancel): " sel
  [[ "$sel" == "0" ]] && return

  if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > total )); then
    fail "Invalid selection."; return
  fi

  local name
  name="$(sed -n "${sel}p" "$DB_FILE" | cut -d: -f1)"
  local ovpn_path="${CLIENT_DIR}/${name}.ovpn"
  local zip_path="${ZIP_DIR}/${name}.zip"

  if [[ ! -f "$ovpn_path" ]]; then
    fail ".ovpn file not found for ${name}."; return
  fi

  zip -j "$zip_path" "$ovpn_path" >/dev/null
  ok "ZIP ready: ${zip_path}"
  show_download_link "$zip_path"
}

# ── Revoke / delete client ────────────────────────────────────────────────────
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
  ./easyrsa --batch gen-crl 2>/dev/null || true
  cp pki/crl.pem /etc/openvpn/server/crl.pem 2>/dev/null || true
  cd - >/dev/null

  rm -f "${CLIENT_DIR}/${name}.ovpn" "${ZIP_DIR}/${name}.zip"
  sed -i "/^${name}:/d" "$DB_FILE"

  # add crl-verify to server config if not already there
  grep -q "crl-verify" /etc/openvpn/server/server.conf || \
    echo "crl-verify /etc/openvpn/server/crl.pem" >> /etc/openvpn/server/server.conf

  systemctl restart openvpn-server@server || true

  ok "Client '${name}' revoked and removed."
}

# ── Show server status ────────────────────────────────────────────────────────
show_status() {
  echo
  echo -e "${CYAN}${BOLD}OpenVPN Server Status${RESET}"
  line
  systemctl status openvpn-server@server --no-pager -l 2>/dev/null || \
    systemctl status openvpn@server --no-pager -l 2>/dev/null || \
    echo "Could not get service status."
  echo
  if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
    echo -e "${BOLD}Connected clients:${RESET}"
    cat /var/log/openvpn/openvpn-status.log
  fi
}

show_summary() {
  local total pub_ip
  total="$(count_clients)"
  pub_ip="$(get_public_ip)"
  echo
  line
  echo -e "${BOLD}Project        :${RESET} ${PROJECT_NAME}"
  echo -e "${BOLD}Public IPv4    :${RESET} ${pub_ip:-N/A}"
  echo -e "${BOLD}Total Clients  :${RESET} ${total}"
  echo -e "${BOLD}Client configs :${RESET} ${CLIENT_DIR}/"
  echo -e "${BOLD}ZIP archives   :${RESET} ${ZIP_DIR}/"
  echo -e "${BOLD}Command        :${RESET} sudo openvpnbuilder"
  echo -e "${BOLD}GitHub         :${RESET} ${PROJECT_REPO}"
  line
  echo
}

menu() {
  title
  show_summary
  echo -e "${BOLD}1)${RESET} Create Single Client"
  echo -e "${BOLD}2)${RESET} Create Bulk Clients  ${DIM}(generates ZIP download)${RESET}"
  echo -e "${BOLD}3)${RESET} List All Clients"
  echo -e "${BOLD}4)${RESET} Download Client ZIP"
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
      1) create_one;      pause ;;
      2) create_bulk;     pause ;;
      3) list_clients;    pause ;;
      4) download_single; pause ;;
      5) revoke_client;   pause ;;
      6) show_status;     pause ;;
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
