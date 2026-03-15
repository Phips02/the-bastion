#!/usr/bin/env bash
# =============================================================================
# setup-rsync-client.sh
# Configure un serveur source pour envoyer ses backups via the-bastion
# À exécuter SUR CHAQUE SERVEUR SOURCE (en root)
#
# Ce script :
#   1. Génère une clé SSH dédiée backup (si absente)
#   2. Affiche la clé publique → à passer à 01-create-backup-account.sh
#   3. Crée le script de backup /opt/backup/run-backup.sh
#   4. Installe un cron quotidien (optionnel)
#
# Usage :
#   ./setup-rsync-client.sh [OPTIONS]
#
# Exemple :
#   ./setup-rsync-client.sh \
#     --server-name zabbix \
#     --bastion-ip 192.168.2.102 \
#     --srv-backup-ip 192.168.2.111 \
#     --srv-backup-user usr-rsync \
#     --backup-src "/etc /var/lib/zabbix"
# =============================================================================

set -euo pipefail

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BACKUP_DIR="/opt/backup"
KEY_FILE="$BACKUP_DIR/id_ed25519"
SCRIPT_FILE="$BACKUP_DIR/run-backup.sh"
LOG_FILE="/var/log/backup-rsync.log"
CRON_HOUR="2"
CRON_MIN="0"

# ─── Fonctions utilitaires ───────────────────────────────────────────────────
log()   { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options obligatoires :
  --server-name      Nom court du serveur (ex: zabbix, n8n, pivpn)
  --bastion-ip       IP du bastion (ex: 192.168.2.102)
  --srv-backup-ip    IP de srv-backup (ex: 192.168.2.111)
  --srv-backup-user  User SSH sur srv-backup (ex: usr-rsync)

Options facultatives :
  --backup-src       Chemins à sauvegarder, séparés par des espaces (défaut: /etc /home /root)
  --backup-dest      Dossier destination sur srv-backup (défaut: /backup/<server-name>)
  --cron-hour        Heure d'exécution du cron (défaut: 2)
  --cron-min         Minute d'exécution du cron (défaut: 0)
  --no-cron          Ne pas installer de cron
  --print-key-only   Affiche uniquement la clé publique et quitte
  --backup-dir       Répertoire de travail backup (défaut: /opt/backup)
  -h, --help         Affiche cette aide
EOF
    exit 0
}

# ─── Parse des arguments ─────────────────────────────────────────────────────
SERVER_NAME=""
BASTION_IP=""
SRV_BACKUP_IP=""
SRV_BACKUP_USER="usr-rsync"
BACKUP_SRC="/etc /home /root"
BACKUP_DEST=""
NO_CRON=false
PRINT_KEY_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-name)      SERVER_NAME="$2";      shift 2 ;;
        --bastion-ip)       BASTION_IP="$2";       shift 2 ;;
        --srv-backup-ip)    SRV_BACKUP_IP="$2";    shift 2 ;;
        --srv-backup-user)  SRV_BACKUP_USER="$2";  shift 2 ;;
        --backup-src)       BACKUP_SRC="$2";       shift 2 ;;
        --backup-dest)      BACKUP_DEST="$2";      shift 2 ;;
        --cron-hour)        CRON_HOUR="$2";        shift 2 ;;
        --cron-min)         CRON_MIN="$2";         shift 2 ;;
        --backup-dir)       BACKUP_DIR="$2"; KEY_FILE="$BACKUP_DIR/id_ed25519"; SCRIPT_FILE="$BACKUP_DIR/run-backup.sh"; shift 2 ;;
        --no-cron)          NO_CRON=true;          shift ;;
        --print-key-only)   PRINT_KEY_ONLY=true;   shift ;;
        -h|--help)          usage ;;
        *) error "Argument inconnu : $1" ;;
    esac
done

# ─── Mode print-key-only ─────────────────────────────────────────────────────
if $PRINT_KEY_ONLY; then
    [[ -f "${KEY_FILE}.pub" ]] && cat "${KEY_FILE}.pub" && exit 0
    error "Clé publique introuvable : ${KEY_FILE}.pub — lancez d'abord ce script sans --print-key-only"
fi

# ─── Validation ──────────────────────────────────────────────────────────────
[[ "$(id -u)" -ne 0 ]] && error "Ce script doit être exécuté en root"
[[ -z "$SERVER_NAME" ]]   && error "--server-name est requis"
[[ -z "$BASTION_IP" ]]    && error "--bastion-ip est requis"
[[ -z "$SRV_BACKUP_IP" ]] && error "--srv-backup-ip est requis"
# SRV_BACKUP_USER a une valeur par défaut (usr-rsync), pas de validation requise

BASTION_ACCOUNT="backup-${SERVER_NAME}"
[[ -z "$BACKUP_DEST" ]] && BACKUP_DEST="/backup/${SERVER_NAME}"

# ─── Résumé ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "   Setup client rsync backup : $SERVER_NAME"
echo "══════════════════════════════════════════════════"
echo ""
log "Serveur       : $SERVER_NAME"
log "Compte bastion: $BASTION_ACCOUNT"
log "Bastion       : $BASTION_IP"
log "srv-backup    : $SRV_BACKUP_USER@$SRV_BACKUP_IP:$BACKUP_DEST"
log "Sources       : $BACKUP_SRC"
log "Répertoire    : $BACKUP_DIR"
$NO_CRON && log "Cron          : désactivé" || log "Cron          : ${CRON_HOUR}h${CRON_MIN} chaque nuit"
echo ""

# ─── Étape 1 : Répertoire et clé SSH ─────────────────────────────────────────
log "Étape 1/4 : Préparation du répertoire et de la clé SSH..."

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [[ -f "$KEY_FILE" ]]; then
    warn "Clé SSH déjà présente : $KEY_FILE (non régénérée)"
else
    ssh-keygen -t ed25519 -N "" -C "backup-${SERVER_NAME}@$(hostname -s)" -f "$KEY_FILE"
    ok "Clé SSH générée : $KEY_FILE"
fi

chmod 600 "$KEY_FILE"
chmod 644 "${KEY_FILE}.pub"
ok "Permissions clé OK"
echo ""

# ─── Étape 2 : Affichage clé publique ────────────────────────────────────────
echo "══════════════════════════════════════════════════"
echo -e "${YELLOW}ACTION REQUISE — Clé publique à enregistrer sur le bastion :${NC}"
echo ""
cat "${KEY_FILE}.pub"
echo ""
echo "Sur votre machine admin, lancez :"
echo ""
echo "  ./admin/01-create-backup-account.sh \\"
echo "    --bastion-ip $BASTION_IP \\"
echo "    --bastion-account <votre-compte-admin> \\"
echo "    --bastion-key ~/.ssh/<votre-cle-admin> \\"
echo "    --account $BASTION_ACCOUNT \\"
echo "    --pubkey \"\$(cat ${KEY_FILE}.pub)\""
echo ""
echo "══════════════════════════════════════════════════"
echo ""

# ─── Étape 3 : Script de backup ──────────────────────────────────────────────
log "Étape 3/4 : Création du script de backup $SCRIPT_FILE..."

# Convertit la liste des sources en tableau
read -ra SRC_ARRAY <<< "$BACKUP_SRC"

# Construit la liste rsync des sources
RSYNC_SOURCES=""
for src in "${SRC_ARRAY[@]}"; do
    RSYNC_SOURCES+="    \"$src\" \\\\"$'\n'
done
# Retire le dernier backslash
RSYNC_SOURCES="${RSYNC_SOURCES%\\\\$'\n'}"
RSYNC_SOURCES+=$'\n'

cat > "$SCRIPT_FILE" <<SCRIPT_EOF
#!/usr/bin/env bash
# =============================================================================
# Script de backup rsync via the-bastion
# Généré par setup-rsync-client.sh le $(date '+%Y-%m-%d')
# Serveur : $SERVER_NAME
# =============================================================================

set -euo pipefail

SERVER_NAME="$SERVER_NAME"
BASTION_ACCOUNT="$BASTION_ACCOUNT"
BASTION_IP="$BASTION_IP"
SRV_BACKUP_IP="$SRV_BACKUP_IP"
SRV_BACKUP_USER="$SRV_BACKUP_USER"
BACKUP_DEST="$BACKUP_DEST"
KEY_FILE="$KEY_FILE"
LOG_FILE="$LOG_FILE"

# Destinations rsync via the-bastion
# Format : <compte-bastion>@<bastion-ip>:<srv-backup-ip>@<backup-user><dest-path>
# Wrapper SSH pour the-bastion (syntaxe --osh rsync)
# Doc : https://ovh.github.io/the-bastion/plugins/open/rsync.html
RSYNC_RSH="ssh -T -i \${KEY_FILE} -o StrictHostKeyChecking=accept-new -o BatchMode=yes \${BASTION_ACCOUNT}@\${BASTION_IP} -p 22 -- --osh rsync --"
RSYNC_DEST="\${SRV_BACKUP_USER}@\${SRV_BACKUP_IP}:\${BACKUP_DEST}"

# Options rsync
RSYNC_OPTS=(
    -va
    --delete
    --delete-excluded
    --exclude="*.tmp"
    --exclude="*.swp"
    --exclude="/proc/*"
    --exclude="/sys/*"
    --exclude="/dev/*"
    --exclude="/run/*"
)

# Sources à sauvegarder
SOURCES=(
$RSYNC_SOURCES)

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [\$SERVER_NAME] \$*" | tee -a "\$LOG_FILE"; }

log "=== Début du backup ==="
ERRORS=0

for src in "\${SOURCES[@]}"; do
    if [[ ! -e "\$src" ]]; then
        log "WARN: source introuvable, ignorée : \$src"
        continue
    fi

    log "Sync: \$src → \$RSYNC_DEST\$(basename \$src)/"

    rsync "\${RSYNC_OPTS[@]}" \\
        --rsh "\${RSYNC_RSH}" \\
        "\$src" \\
        "\${RSYNC_DEST}/\$(basename \$src)/" || {
            log "ERROR: échec rsync pour \$src"
            ERRORS=\$((ERRORS + 1))
        }
done

if [[ \$ERRORS -eq 0 ]]; then
    log "=== Backup terminé avec succès ==="
else
    log "=== Backup terminé avec \$ERRORS erreur(s) ==="
    exit 1
fi
SCRIPT_EOF

chmod 700 "$SCRIPT_FILE"
ok "Script de backup créé : $SCRIPT_FILE"
echo ""

# ─── Étape 4 : Cron ──────────────────────────────────────────────────────────
if $NO_CRON; then
    log "Étape 4/4 : Cron ignoré (--no-cron)"
else
    log "Étape 4/4 : Installation du cron quotidien (${CRON_MIN} ${CRON_HOUR} * * *)..."
    CRON_LINE="${CRON_MIN} ${CRON_HOUR} * * * root $SCRIPT_FILE >> $LOG_FILE 2>&1"
    CRON_FILE="/etc/cron.d/backup-${SERVER_NAME}"

    cat > "$CRON_FILE" <<CRON_EOF
# Backup rsync via the-bastion — $SERVER_NAME
# Généré le $(date '+%Y-%m-%d')
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

$CRON_LINE
CRON_EOF

    chmod 644 "$CRON_FILE"
    ok "Cron installé : $CRON_FILE"
fi

# ─── Résumé final ────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo -e "${GREEN}✔ Client backup configuré avec succès !${NC}"
echo ""
echo "Récapitulatif :"
echo "  • Clé SSH backup : $KEY_FILE"
echo "  • Script backup  : $SCRIPT_FILE"
echo "  • Sources        : $BACKUP_SRC"
echo "  • Destination    : $BASTION_ACCOUNT@$BASTION_IP:$SRV_BACKUP_IP@$SRV_BACKUP_USER$BACKUP_DEST"
$NO_CRON || echo "  • Cron           : ${CRON_MIN} ${CRON_HOUR} * * * (quotidien)"
echo ""
echo -e "${YELLOW}⚠ Prochaines étapes :${NC}"
echo "  1. Enregistrer la clé publique ci-dessus sur le bastion (voir commande étape 2)"
echo "  2. Tester manuellement : $SCRIPT_FILE"
echo "  3. Vérifier les logs   : tail -f $LOG_FILE"
echo ""
