#!/bin/bash
clear
# Auto-fix Windows line endings
sed -i 's/\r$//' "$0" 2>/dev/null

# ==========================================
# COLORS & GRAPHICS
# ==========================================
RED='\033[1;31m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[1;35m'
NC='\033[0m' # No Color
ICON_OK="${GREEN}✔${NC}"
ICON_FAIL="${RED}✘${NC}"
ICON_ARROW="${MAGENTA}➤${NC}"

# ==========================================
# HELPER FUNCTIONS
# ==========================================
print_header() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}         🔐  SSL CERTIFICATE MANAGER  🔐            ${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}               ⚡ Powered by acme.sh                ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

check_status() {
    if [ $? -eq 0 ]; then
        echo -e "$ICON_OK $1"
    else
        echo -e "$ICON_FAIL $2"
        exit 1
    fi
}

# Check Root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: Please run as root!${NC}"; exit 1; 
fi

print_header

# ==========================================
# 1. PREREQUISITES
# ==========================================
echo -e "${YELLOW}:: Checking Prerequisites...${NC}"

if ! command -v curl &> /dev/null || ! command -v socat &> /dev/null; then
    echo -e "   Installing curl, socat, cron..."
    apt update -q && apt install -y curl socat cron tar > /dev/null 2>&1
fi

ACME_BIN="$HOME/.acme.sh/acme.sh"
if [ ! -f "$ACME_BIN" ]; then
    echo -e "   Installing acme.sh..."
    curl -s https://get.acme.sh | sh > /dev/null
    check_status "acme.sh installed." "Failed to install acme.sh"
    [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
else
    echo -e "$ICON_OK acme.sh is ready."
fi

# ==========================================
# 2. DOMAIN SELECTION
# ==========================================
echo ""
echo -e "${CYAN}:: Domain Configuration${NC}"
echo -e "   ${YELLOW}Tip: You can enter multiple domains separated by space.${NC}"
read -e -p "   Enter Domain(s): " ALL_DOMAINS

if [ -z "$ALL_DOMAINS" ]; then echo -e "${RED}Domain cannot be empty!${NC}"; exit 1; fi

DOMAIN_LIST=($ALL_DOMAINS)
MAIN_DOMAIN=${DOMAIN_LIST[0]}

# Build Flags
ACME_DOMAIN_FLAGS=""
for D in "${DOMAIN_LIST[@]}"; do
    ACME_DOMAIN_FLAGS="$ACME_DOMAIN_FLAGS -d $D"
done

# ==========================================
# 3. CHECK EXISTING CERT
# ==========================================
CERT_ECC="$HOME/.acme.sh/${MAIN_DOMAIN}_ecc"
CERT_RSA="$HOME/.acme.sh/${MAIN_DOMAIN}"
SKIP_ISSUANCE=0
KEY_LENGTH="ec-256" # Default

if [ -d "$CERT_ECC" ] || [ -d "$CERT_RSA" ]; then
    echo -e "\n${MAGENTA}!! Certificate already exists for $MAIN_DOMAIN !!${NC}"
    echo "   1) Renew existing certificate"
    echo "   2) Revoke & Create FRESH certificate"
    read -p "   Select option [1-2]: " exist_action

    if [ "$exist_action" == "1" ]; then
        echo -e "\n${YELLOW}:: Renewing Certificate...${NC}"
        "$ACME_BIN" --renew -d "$MAIN_DOMAIN" --force
        check_status "Renewal successful!" "Renewal Failed! Check logs."
        SKIP_ISSUANCE=1
    else
        echo -e "\n${YELLOW}:: Removing old certificate...${NC}"
        "$ACME_BIN" --remove -d "$MAIN_DOMAIN" > /dev/null 2>&1
        rm -rf "$CERT_ECC" "$CERT_RSA"
        echo -e "$ICON_OK Old certificate removed."
    fi
fi

# ==========================================
# 4. ISSUANCE (Smart Logic)
# ==========================================
if [ "$SKIP_ISSUANCE" -eq 0 ]; then
    echo -e "\n${CYAN}:: Certificate Settings${NC}"
    
    # Key Type
    echo -e "   ${ICON_ARROW} Algorithm:"
    echo -e "     1) RSA-2048 (Legacy)"
    echo -e "     2) ECDSA P-256 (High Performance) ${GREEN}[Recommended]${NC}"
    read -p "     Select [1-2]: " k_opt
    [ "$k_opt" == "1" ] && KEY_LENGTH="2048" || KEY_LENGTH="ec-256"

    # Define Expected Cert Path for Smart Check
    if [ "$KEY_LENGTH" == "ec-256" ]; then
        EXPECTED_CERT_FILE="$HOME/.acme.sh/${MAIN_DOMAIN}_ecc/${MAIN_DOMAIN}.cer"
    else
        EXPECTED_CERT_FILE="$HOME/.acme.sh/${MAIN_DOMAIN}/${MAIN_DOMAIN}.cer"
    fi

    # Mode Selection
    echo -e "\n   ${ICON_ARROW} Validation Mode:"
    echo "     1) Wildcard (DNS - *.$MAIN_DOMAIN)"
    echo "     2) Standard / Multi-Domain (HTTP - Port 80)"
    echo "     3) Manual DNS (TXT Record)"
    read -p "     Select [1-3]: " mode_opt
    
    CMD=""
    IS_MANUAL=0
    
    case $mode_opt in
        1)
            # Wildcard
            FLAGS="-d $MAIN_DOMAIN -d *.$MAIN_DOMAIN"
            echo -e "\n   ${ICON_ARROW} DNS Provider:"
            echo "     1) Cloudflare API"
            echo "     2) Manual TXT"
            read -p "     Select [1-2]: " wc_dns
            
            if [ "$wc_dns" == "1" ]; then
                read -e -p "     -> Cloudflare Token: " CF_Token
                read -e -p "     -> Cloudflare Account ID: " CF_Account_ID
                export CF_Token CF_Account_ID
                CMD="$ACME_BIN --issue $FLAGS --dns dns_cf --keylength $KEY_LENGTH"
            else
                # Manual Wildcard
                CMD="$ACME_BIN --issue $FLAGS --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please --keylength $KEY_LENGTH"
                IS_MANUAL=1
            fi
            ;;
        2)
            # Standard HTTP
            echo -e "${YELLOW}:: Ensuring Port 80 is free...${NC}"
            CMD="$ACME_BIN --issue $ACME_DOMAIN_FLAGS --standalone --keylength $KEY_LENGTH"
            ;;
        3)
            # Manual DNS List
            CMD="$ACME_BIN --issue $ACME_DOMAIN_FLAGS --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please --keylength $KEY_LENGTH"
            IS_MANUAL=1
            FLAGS="$ACME_DOMAIN_FLAGS" # For manual renew step
            ;;
        *)
            CMD="$ACME_BIN --issue $ACME_DOMAIN_FLAGS --standalone --keylength $KEY_LENGTH"
            ;;
    esac

    # Execute
    echo -e "\n${YELLOW}:: Processing Request...${NC}"
    
    if [ "$IS_MANUAL" -eq 1 ]; then
        # Run Issue First
        eval "$CMD"
        
        # SMART CHECK: Did it issue immediately (cached TXT)?
        if [ -f "$EXPECTED_CERT_FILE" ]; then
            echo -e "\n${GREEN}✔ Verification Cached! Certificate issued immediately.${NC}"
            echo -e "   Skipping manual TXT step..."
        else
            # Not found -> It's waiting for TXT
            echo -e "\n${RED}>>> ACTION REQUIRED: Add TXT record(s) to DNS <<<${NC}"
            read -p "    Press ENTER after adding..."
            
            # Now Renew/Verify
            RENEW_CMD="$ACME_BIN --renew $FLAGS --yes-I-know-dns-manual-mode-enough-go-ahead-please --dns"
            eval "$RENEW_CMD"
            check_status "Certificate Issued Successfully!" "Issuance FAILED."
        fi
    else
        # Automated Modes (HTTP / CF)
        eval "$CMD"
        check_status "Certificate Issued Successfully!" "Issuance FAILED."
    fi
fi

# ==========================================
# 5. INSTALLATION / COPY
# ==========================================
echo -e "\n${CYAN}:: Installation Path${NC}"
echo "   1) /etc/nginx/ssl"
echo "   2) /var/lib/marznode"
echo "   3) Custom Path"
read -p "   Select [1-3]: " p_opt

case $p_opt in
    1) T_DIR="/etc/nginx/ssl" ;;
    2) T_DIR="/var/lib/marznode" ;;
    3) read -e -p "   -> Enter Full Path: " T_DIR ;;
    *) T_DIR="/etc/nginx/ssl" ;;
esac

if [ ! -d "$T_DIR" ]; then
    echo -e "   ${YELLOW}Creating directory: $T_DIR${NC}"
    mkdir -p "$T_DIR"
fi

echo -e "\n${YELLOW}:: Installing Certificate...${NC}"

# Detect flags for install
[ "$KEY_LENGTH" == "ec-256" ] && ECC_FLAG="--ecc" || ECC_FLAG=""
if [ "$SKIP_ISSUANCE" -eq 1 ]; then
    [ -d "$CERT_ECC" ] && ECC_FLAG="--ecc"
    [ -d "$CERT_RSA" ] && ECC_FLAG=""
fi

# Set Correct Domain Flags for Install
INSTALL_FLAGS="-d $MAIN_DOMAIN"
if [ "$mode_opt" == "1" ] && [ "$SKIP_ISSUANCE" -eq 0 ]; then
   INSTALL_FLAGS="-d $MAIN_DOMAIN -d *.$MAIN_DOMAIN"
fi

"$ACME_BIN" --install-cert $INSTALL_FLAGS $ECC_FLAG \
    --fullchain-file "$T_DIR/${MAIN_DOMAIN}.crt" \
    --key-file "$T_DIR/${MAIN_DOMAIN}.key" \
    --reloadcmd "echo 'Cert Updated'"

check_status "Certificate Installed!" "Installation Failed!"

# ==========================================
# 6. CRON JOB
# ==========================================
CRON_CMD="$HOME/.acme.sh/acme.sh --renew-all --quiet"
(crontab -l 2>/dev/null | grep -F "acme.sh --renew-all") || (crontab -l 2>/dev/null; echo "0 0 */30 * * $CRON_CMD") | crontab -

# ==========================================
# 7. SUMMARY
# ==========================================
echo -e "\n${BLUE}============================================================${NC}"
echo -e " ${GREEN}SUCCESS! Certificate is ready.${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e " ${ICON_ARROW} Main Domain: ${GREEN}$MAIN_DOMAIN${NC}"
echo -e " ${ICON_ARROW} CRT File:    ${YELLOW}$T_DIR/${MAIN_DOMAIN}.crt${NC}"
echo -e " ${ICON_ARROW} Key File:    ${YELLOW}$T_DIR/${MAIN_DOMAIN}.key${NC}"
echo -e " ${ICON_ARROW} Renewal:     ${GREEN}Auto (Every 30 days)${NC}"
echo -e "${BLUE}============================================================${NC}"
