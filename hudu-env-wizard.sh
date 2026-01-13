#!/usr/bin/env bash
set -euo pipefail

# Hudu Self-Hosted .env Wizard
# Generates a production-ready .env file for Hudu self-hosting.

# ---------- colors & formatting ----------
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# ---------- helpers ----------
die() { echo -e "${YELLOW}✗${RESET} $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local s="$*"
  echo "$s" | LC_ALL=C sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

print_step() {
  echo -e "\n${BOLD}${CYAN}[$1]${RESET} ${BOLD}$2${RESET}"
}

prompt_required() {
  local label="$1" hint="${2:-}" var
  while true; do
    if [[ -n "$hint" ]]; then
      read -r -p "    $label ($hint): " var || exit 1
    else
      read -r -p "    $label: " var || exit 1
    fi
    var="$(trim "$var")"
    [[ -n "$var" ]] && { echo "$var"; return 0; }
    echo -e "    ${YELLOW}↳ Required field. Please enter a value.${RESET}"
  done
}

prompt_optional() {
  local label="$1" hint="${2:-}" var
  if [[ -n "$hint" ]]; then
    read -r -p "    $label ($hint, optional): " var || exit 1
  else
    read -r -p "    $label (optional): " var || exit 1
  fi
  echo "$(trim "$var")"
}

prompt_yes_no() {
  local label="$1" default="$2" v
  local hint="y/n"
  [[ "$default" == "yes" ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -r -p "    $label [$hint]: " v || exit 1
    v="$(trim "$v")"
    [[ -z "$v" ]] && v="$default"
    v="$(echo "$v" | tr '[:upper:]' '[:lower:]')"
    case "$v" in
      y|yes) echo "yes"; return 0 ;;
      n|no)  echo "no"; return 0 ;;
      *) echo -e "    ${YELLOW}↳ Please enter 'yes' or 'no'.${RESET}" ;;
    esac
  done
}

prompt_secret_hidden() {
  local label="$1" v
  while true; do
    read -r -s -p "    $label: " v || exit 1
    echo
    # Strip newlines and carriage returns (can appear when pasting)
    v="${v//$'\n'/}"
    v="${v//$'\r'/}"
    v="$(trim "$v")"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
    echo -e "    ${YELLOW}↳ Required field. Please enter a value.${RESET}"
  done
}

gen_rand_hex() {
  local nbytes="$1"
  if have openssl; then
    openssl rand -hex "$nbytes"
  else
    head -c "$nbytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

gen_rand_ascii() {
  local length="$1"
  # Outputs a random alphanumeric string of requested length (ASCII-safe).
  # macOS/BSD tr may error without LC_CTYPE=C.
  # Subshell + || true prevents SIGPIPE exit (when head closes early) from failing under pipefail.
  ( LC_CTYPE=C tr -dc 'A-Za-z0-9' < /dev/urandom || true ) | head -c "$length"
}

# dotenv single-quote escaping: ' -> '"'"'
dq() {
  local v="$1"
  v="$(printf "%s" "$1" | LC_ALL=C sed "s/'/'\"'\"'/g")"
  printf "'%s'" "$v"
}

write_kv() {
  local k="$1" v="$2"
  printf "%s=%s\n" "$k" "$(dq "$v")"
}

# ---------- intro ----------
clear 2>/dev/null || true
cat <<'BANNER'

  ╦ ╦╦ ╦╔╦╗╦ ╦
  ╠═╣║ ║ ║║║ ║
  ╩ ╩╚═╝═╩╝╚═╝
  Self-Hosted .env Wizard

BANNER

echo -e "${DIM}This wizard will generate a .env file for your Hudu instance.${RESET}"

# ---------- output path ----------
OUT=".env"

if [[ -e "$OUT" ]]; then
  echo
  c="$(prompt_yes_no "A .env file already exists. Overwrite?" "no")"
  [[ "$c" == "yes" ]] || die "Cancelled."
fi

# ---------- step 1: domain ----------
print_step "1/2" "Domain Setup"
echo -e "    ${DIM}Your Hudu instance needs a subdomain on your domain.${RESET}"
echo

SUBDOMAIN="$(prompt_required "Subdomain" "e.g. hudu, docs, it")"
DOMAIN_ROOT="$(prompt_required "Root domain" "e.g. example.com")"
FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN_ROOT}"

echo -e "\n    ${GREEN}✓${RESET} Your Hudu URL: ${BOLD}https://${FULL_DOMAIN}${RESET}"

# ---------- step 2: storage ----------
print_step "2/2" "File Storage"
echo -e "    ${DIM}Where should Hudu store uploaded files (documents, images, etc.)?${RESET}"
echo
echo -e "    ${BOLD}Local${RESET}  - Files stored on this server's disk"
echo -e "            ${DIM}Simple setup, but files lost if server dies${RESET}"
echo
echo -e "    ${BOLD}Cloud${RESET}  - Files stored in S3-compatible storage"
echo -e "            ${DIM}Works with AWS S3, Backblaze B2, MinIO, Wasabi, etc.${RESET}"
echo -e "            ${DIM}Better for backups and scaling${RESET}"
echo

S3_BUCKET=""
S3_ACCESS_KEY_ID=""
S3_SECRET_ACCESS_KEY=""
S3_REGION=""
S3_ENDPOINT=""
USE_LOCAL_FILESYSTEM="true"

USE_S3="$(prompt_yes_no "Use cloud storage (S3)?" "no")"

if [[ "$USE_S3" == "yes" ]]; then
  USE_LOCAL_FILESYSTEM="false"
  echo
  echo -e "    ${DIM}Enter your S3 bucket details:${RESET}"
  S3_BUCKET="$(prompt_required "Bucket name")"
  S3_REGION="$(prompt_required "Region" "e.g. us-east-1")"
  S3_ACCESS_KEY_ID="$(prompt_required "Access Key ID")"
  S3_SECRET_ACCESS_KEY="$(prompt_secret_hidden "Secret Access Key")"
  echo
  S3_ENDPOINT="$(prompt_optional "Custom endpoint" "leave blank for AWS")"
  echo -e "\n    ${GREEN}✓${RESET} Cloud storage configured"
else
  echo -e "\n    ${GREEN}✓${RESET} Using local storage"
fi

# ---------- generate secrets ----------
echo -e "\n${DIM}Generating secure keys...${RESET}"
SECRET_KEY_BASE="$(gen_rand_hex 64)"
PASSWORD_KEY="$(gen_rand_ascii 32)"
TWO_FACTOR_KEY="$(gen_rand_ascii 32)"

# ---------- defaults ----------
PUID="1000"
PGID="1000"
DB_PASSWORD=""

# SMTP left blank for later configuration
SMTP_DOMAIN=""
SMTP_ADDRESS=""
SMTP_PORT=""
SMTP_USERNAME=""
SMTP_PASSWORD=""
SMTP_AUTHENTICATION=""
SMTP_VERIFY_MODE=""
SMTP_FROM_ADDRESS=""

# ---------- write .env ----------
umask 077
{
  echo "# Hudu Self-Hosted .env"
  echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Docs: https://support.hudu.com/"
  echo

  echo "# ── Core ──────────────────────────────────────────"
  write_kv "SECRET_KEY_BASE" "$SECRET_KEY_BASE"
  write_kv "PASSWORD_KEY" "$PASSWORD_KEY"
  write_kv "TWO_FACTOR_KEY" "$TWO_FACTOR_KEY"
  echo

  echo "# ── Domain ────────────────────────────────────────"
  write_kv "DOMAIN" "$FULL_DOMAIN"
  write_kv "URL" "$DOMAIN_ROOT"
  write_kv "SUBDOMAINS" "$SUBDOMAIN"
  write_kv "ONLY_SUBDOMAINS" "true"
  write_kv "VALIDATION" "http"
  write_kv "STAGING" "false"
  echo

  echo "# ── Database ──────────────────────────────────────"
  write_kv "DB_HOST" "db"
  write_kv "DB_USERNAME" "postgres"
  write_kv "DB_PASSWORD" "$DB_PASSWORD"
  write_kv "DB_NAME" "hudu_production"
  write_kv "POSTGRES_HOST_AUTH_METHOD" "trust"
  echo

  echo "# ── SMTP (configure these to enable email) ───────"
  write_kv "SMTP_DOMAIN" "$SMTP_DOMAIN"
  write_kv "SMTP_ADDRESS" "$SMTP_ADDRESS"
  write_kv "SMTP_PORT" "$SMTP_PORT"
  write_kv "SMTP_STARTTLS_AUTO" "true"
  write_kv "SMTP_USERNAME" "$SMTP_USERNAME"
  write_kv "SMTP_PASSWORD" "$SMTP_PASSWORD"
  write_kv "SMTP_AUTHENTICATION" "$SMTP_AUTHENTICATION"
  write_kv "SMTP_OPENSSL_VERIFY_MODE" "$SMTP_VERIFY_MODE"
  write_kv "SMTP_FROM_ADDRESS" "$SMTP_FROM_ADDRESS"
  echo

  echo "# ── Storage ───────────────────────────────────────"
  write_kv "USE_LOCAL_FILESYSTEM" "$USE_LOCAL_FILESYSTEM"
  write_kv "AUTHENTICATE_UPLOADS" "true"
  write_kv "S3_ENDPOINT" "$S3_ENDPOINT"
  write_kv "S3_BUCKET" "$S3_BUCKET"
  write_kv "S3_ACCESS_KEY_ID" "$S3_ACCESS_KEY_ID"
  write_kv "S3_SECRET_ACCESS_KEY" "$S3_SECRET_ACCESS_KEY"
  write_kv "S3_REGION" "$S3_REGION"
  echo

  echo "# ── Runtime ───────────────────────────────────────"
  write_kv "PUID" "$PUID"
  write_kv "PGID" "$PGID"
  write_kv "RAILS_ENV" "production"
  write_kv "RACK_ENV" "production"
  write_kv "RAILS_MAX_THREADS" "3"
  write_kv "REDIS_URL" "redis://redis"
} > "$OUT"

chmod 600 "$OUT" 2>/dev/null || true

# ---------- done ----------
echo
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}✓${RESET} ${BOLD}Done!${RESET} Your .env file has been created."
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo
echo -e "  ${BOLD}File:${RESET}  $OUT"
echo -e "  ${BOLD}URL:${RESET}   https://${FULL_DOMAIN}"
echo
echo -e "  ${YELLOW}Next steps:${RESET}"
echo -e "    1. Review the .env and adjust any settings as needed"
echo -e "    2. Complete the rest of the setup guide to get Hudu running"
echo -e "    3. Once the server is up, configure SMTP: ${BOLD}Admin → SMTP Setup${RESET}"
echo
echo -e "  ${YELLOW}⚠ Important:${RESET}"
echo -e "    Copy this .env file somewhere secure. Losing it could mean"
echo -e "    losing access to passwords and other encrypted data."
echo
