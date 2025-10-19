#!/usr/bin/env bash
set -euo pipefail

# =========================
# Certbot Auto-Setup Script
# =========================
# Supports: Ubuntu/Debian (systemd), Nginx/Apache/Standalone/Webroot
#
# Non-interactive mode: export variables before running, e.g.:
#   SERVER_TYPE=nginx \
#   DOMAINS="example.com,www.example.com" \
#   EMAIL="admin@example.com" \
#   REDIRECT="y" \
#   STAGING="n" \
#   KEY_TYPE="ecdsa" \
#   EC_CURVE="secp384r1" \
#   WEBROOT_PATH="/var/www/html" \
#   bash certbot_auto.sh
#
# Notes:
# - Uses SNAP Certbot (recommended). Falls back to apt if snap isn't available.
# - Auto-renew is handled by certbot's systemd timer (via snap). This script
#   adds a deploy hook to reload your web server after successful renewals.
# - For standalone mode, ensure port 80 is free while obtaining the cert.

# ---------- Helpers ----------
is_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VER="${VERSION_ID:-}"
  else
    echo "Cannot detect OS. /etc/os-release missing." >&2
    exit 1
  fi
}

prompt_if_empty() {
  local varname="$1"; local prompt="$2"; local def="${3:-}"
  local current="${!varname:-}"
  if [[ -z "${current}" ]]; then
    if [[ -n "$def" ]]; then
      read -r -p "$prompt [$def]: " input || true
      input="${input:-$def}"
    else
      read -r -p "$prompt: " input || true
    fi
    # shellcheck disable=SC2086
    eval $varname'="$input"'
  fi
}

confirm_yn() {
  local varname="$1"; local prompt="$2"; local def="${3:-y}"
  local current="${!varname:-}"
  if [[ -z "${current}" ]]; then
    read -r -p "$prompt (y/n) [$def]: " yn || true
    yn="${yn:-$def}"
    case "$yn" in
      y|Y) eval $varname'="y"';;
      n|N) eval $varname'="n"';;
      *) echo "Please answer y or n."; confirm_yn "$varname" "$prompt" "$def";;
    esac
  fi
}

split_domains() {
  # Accept comma/space separated and normalize to -d args
  local raw="$1"
  raw="${raw//,/ }"
  local args=()
  for d in $raw; do
    [[ -n "$d" ]] && args+=("-d" "$d")
  done
  printf "%s " "${args[@]}"
}

enable_service() {
  local svc="$1"
  if systemctl list-unit-files | grep -q "^${svc}\.service"; then
    systemctl enable --now "$svc" || true
  fi
}

# ---------- Preconditions ----------
need_root
detect_os

if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  echo "Warning: this script is tailored for Ubuntu/Debian. Proceeding anyway..." >&2
fi

# ---------- Gather Inputs ----------
prompt_if_empty SERVER_TYPE "Choose server type (nginx/apache/standalone/webroot)" "nginx"
prompt_if_empty DOMAINS "Enter domain(s) (comma or space separated; e.g. example.com,www.example.com)"
prompt_if_empty EMAIL "Admin email for Let's Encrypt (important for expiry notices)"
confirm_yn REDIRECT "Force HTTPS redirect (applicable to nginx/apache)?" "y"
confirm_yn STAGING "Use Let's Encrypt staging (for testing to avoid rate limits)?" "n"
prompt_if_empty KEY_TYPE "Key type (rsa/ecdsa)" "ecdsa"
if [[ "${KEY_TYPE,,}" == "ecdsa" ]]; then
  prompt_if_empty EC_CURVE "ECDSA curve (secp256r1/secp384r1/secp521r1)" "secp384r1"
fi
if [[ "${SERVER_TYPE,,}" == "webroot" ]]; then
  prompt_if_empty WEBROOT_PATH "Webroot path (e.g. /var/www/html)" "/var/www/html"
fi

SERVER_TYPE="${SERVER_TYPE,,}"
KEY_TYPE="${KEY_TYPE,,}"
REDIRECT="${REDIRECT,,}"
STAGING="${STAGING,,}"

if [[ -z "$DOMAINS" || -z "$EMAIL" ]]; then
  echo "Domains and email are required." >&2
  exit 1
fi

DOM_ARGS=$(split_domains "$DOMAINS")

# ---------- Package Setup ----------
echo "Installing prerequisites..."

# Update apt cache when needed
apt_update_once() {
  if [[ -z "${APT_UPDATED:-}" ]]; then
    apt-get update -y
    APT_UPDATED=1
  fi
}

install_snapd_if_needed() {
  if ! is_cmd snap; then
    echo "snapd not found. Installing snapd..."
    apt_update_once
    apt-get install -y snapd
    enable_service snapd.socket
    sleep 2
  fi
}

install_certbot_snap() {
  install_snapd_if_needed
  echo "Installing Certbot via snap..."
  snap install core >/dev/null || true
  snap refresh core
  snap install --classic certbot
  ln -sf /snap/bin/certbot /usr/bin/certbot
}

install_certbot_apt_fallback() {
  echo "Falling back to apt install of certbot..."
  apt_update_once
  apt-get install -y certbot
}

if ! is_cmd certbot; then
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    install_certbot_snap || install_certbot_apt_fallback
  else
    # Try snap anyway
    install_certbot_snap || install_certbot_apt_fallback
  fi
fi

# Install web servers if user chose them (optional, only if missing)
case "$SERVER_TYPE" in
  nginx)
    if ! is_cmd nginx; then
      echo "Installing Nginx..."
      apt_update_once
      apt-get install -y nginx
      enable_service nginx
    fi
    ;;
  apache)
    if ! is_cmd apache2; then
      echo "Installing Apache..."
      apt_update_once
      apt-get install -y apache2
      enable_service apache2
    fi
    ;;
  standalone|webroot) : ;;
  *)
    echo "Unknown SERVER_TYPE: $SERVER_TYPE" >&2
    exit 1
    ;;
esac

# ---------- Firewall (UFW if present) ----------
if is_cmd ufw; then
  echo "Configuring UFW rules..."
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  if [[ "$SERVER_TYPE" == "nginx" && -f /etc/ufw/applications.d/nginx ]]; then
    ufw allow 'Nginx Full' || true
  fi
fi

# ---------- Obtain Certificate ----------
CERTBOT_COMMON_ARGS=(--agree-tos -m "$EMAIL" --no-eff-email --non-interactive)
[[ "$STAGING" == "y" ]] && CERTBOT_COMMON_ARGS+=(--staging)
if [[ "$KEY_TYPE" == "ecdsa" ]]; then
  CERTBOT_COMMON_ARGS+=(--key-type ecdsa --elliptic-curve "${EC_CURVE}")
else
  CERTBOT_COMMON_ARGS+=(--key-type rsa --rsa-key-size 4096)
fi

echo "Requesting certificate for: $DOMAINS"

case "$SERVER_TYPE" in
  nginx)
    # --redirect automatically configures 80->443
    if [[ "$REDIRECT" == "y" ]]; then
      certbot --nginx $DOM_ARGS "${CERTBOT_COMMON_ARGS[@]}" --redirect
    else
      certbot --nginx $DOM_ARGS "${CERTBOT_COMMON_ARGS[@]}"
    fi
    ;;
  apache)
    if [[ "$REDIRECT" == "y" ]]; then
      certbot --apache $DOM_ARGS "${CERTBOT_COMMON_ARGS[@]}" --redirect
    else
      certbot --apache $DOM_ARGS "${CERTBOT_COMMON_ARGS[@]}"
    fi
    ;;
  webroot)
    [[ -d "$WEBROOT_PATH" ]] || { echo "Webroot path not found: $WEBROOT_PATH"; exit 1; }
    certbot certonly --webroot -w "$WEBROOT_PATH" $DOM_ARGS "${CERTBOT_COMMON_ARGS[@]}"
    ;;
  standalone)
    # Make sure port 80 is available
    certbot certonly --standalone --preferred-challenges http $DOM_ARGS "${CERTBOT_COMMON_ARGS[@]}"
    ;;
esac

echo "Certificate request complete."

# ---------- Renew Hooks ----------
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
mkdir -p "$HOOK_DIR"
HOOK_FILE="$HOOK_DIR/reload-webserver.sh"

cat > "$HOOK_FILE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# This runs after a successful renewal

reload_if_running() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    systemctl reload "$svc" || systemctl restart "$svc" || true
  fi
}

# Try nginx, apache, then generic web servers
reload_if_running nginx
reload_if_running apache2
# Add any custom services you want to reload here, e.g.:
# reload_if_running "caddy"
# reload_if_running "haproxy"
EOF

chmod +x "$HOOK_FILE"

# ---------- Dry-run renewal test ----------
echo "Testing renewal (dry-run)..."
if certbot renew --dry-run; then
  echo "Dry-run renewal succeeded."
else
  echo "Warning: dry-run renewal reported issues. Check logs at /var/log/letsencrypt/letsencrypt.log"
fi

# ---------- Summary ----------
echo
echo "============================================================"
echo "Let's Encrypt SSL setup is complete!"
echo
echo "Domains:      $DOMAINS"
echo "Email:        $EMAIL"
echo "Server:       $SERVER_TYPE"
echo "Redirect:     $REDIRECT"
echo "Staging:      $STAGING"
echo "Key type:     $KEY_TYPE ${EC_CURVE:+($EC_CURVE)}"
[[ "$SERVER_TYPE" == "webroot" ]] && echo "Webroot:      $WEBROOT_PATH"
echo
echo "Certificates live in: /etc/letsencrypt/live/<your-domain>/"
echo "Auto-renew:   handled by certbot's systemd timer (via snap)."
echo "Deploy hook:  $HOOK_FILE (reloads your web server after renew)"
echo "Logs:         /var/log/letsencrypt/letsencrypt.log"
echo "============================================================"

# sudo bash certbot_auto.sh

# sudo SERVER_TYPE=nginx \
#      DOMAINS="example.com,www.example.com" \
#      EMAIL="admin@example.com" \
#      REDIRECT=y \
#      STAGING=n \
#      KEY_TYPE=ecdsa \
#      EC_CURVE=secp384r1 \
#      bash certbot_auto.sh


# sudo SERVER_TYPE=webroot \
#      WEBROOT_PATH="/var/www/html" \
#      DOMAINS="example.com" \
#      EMAIL="ops@example.com" \
#      REDIRECT=n \
#      bash certbot_auto.sh
