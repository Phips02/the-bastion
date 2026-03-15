#!/usr/bin/env bash
# =============================================================================
# 00-setup-rsync-group.sh
# Setup initial du groupe rsync-backup sur the-bastion
# À exécuter UNE SEULE FOIS par l'admin du bastion
#
# Ce script :
#   1. Crée le groupe rsync-backup
#   2. Ajoute srv-backup comme serveur cible (SSH + protocole rsync)
#   3. Affiche la clé egress publique du groupe → à déposer sur srv-backup
#
# Usage :
#   ./00-setup-rsync-group.sh [OPTIONS]
#
# Exemple :
#   ./00-setup-rsync-group.sh \
#     --bastion-ip 192.168.2.102 \
#     --bastion-account admin \
#     --bastion-key ~/.ssh/admin_bastion \
#     --srv-backup-ip 192.168.2.111 \
#     --srv-backup-user usr-rsync \
#     --srv-backup-port 22
# =============================================================================

set -euo pipefail

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

GROUP_NAME="rsync-backup"

# ─── Fonctions utilitaires ───────────────────────────────────────────────────
log()     { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options obligatoires :
  --bastion-ip       IP du bastion (ex: 192.168.2.102)
  --bastion-account  Compte admin sur le bastion (ex: admin)
  --bastion-key      Chemin de la clé SSH admin (ex: ~/.ssh/admin_bastion)
  --srv-backup-ip    IP de srv-backup (ex: 192.168.2.111)
  --srv-backup-user  User SSH sur srv-backup (ex: usr-rsync)
  --srv-backup-port  Port SSH de srv-backup (défaut: 22)

Options facultatives :
  --group-name       Nom du groupe (défaut: rsync-backup)
  --dry-run          Affiche les commandes sans les exécuter
  -h, --help         Affiche cette aide
EOF
    exit 0
}

# ─── Parse des arguments ─────────────────────────────────────────────────────
BASTION_IP=""
BASTION_ACCOUNT=""
BASTION_KEY=""
SRV_BACKUP_IP=""
SRV_BACKUP_USER=""
SRV_BACKUP_PORT="22"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bastion-ip)       BASTION_IP="$2";       shift 2 ;;
        --bastion-account)  BASTION_ACCOUNT="$2";  shift 2 ;;
        --bastion-key)      BASTION_KEY="$2";      shift 2 ;;
        --srv-backup-ip)    SRV_BACKUP_IP="$2";    shift 2 ;;
        --srv-backup-user)  SRV_BACKUP_USER="$2";  shift 2 ;;
        --srv-backup-port)  SRV_BACKUP_PORT="$2";  shift 2 ;;
        --group-name)       GROUP_NAME="$2";       shift 2 ;;
        --dry-run)          DRY_RUN=true;          shift ;;
        -h|--help)          usage ;;
        *) error "Argument inconnu : $1" ;;
    esac
done

# ─── Validation ──────────────────────────────────────────────────────────────
[[ -z "$BASTION_IP" ]]       && error "--bastion-ip est requis"
[[ -z "$BASTION_ACCOUNT" ]]  && error "--bastion-account est requis"
[[ -z "$BASTION_KEY" ]]      && error "--bastion-key est requis"
[[ -z "$SRV_BACKUP_IP" ]]    && error "--srv-backup-ip est requis"
[[ -z "$SRV_BACKUP_USER" ]]  && error "--srv-backup-user est requis"

BASTION_KEY="${BASTION_KEY/#\~/$HOME}"
[[ ! -f "$BASTION_KEY" ]] && error "Clé SSH introuvable : $BASTION_KEY"

# ─── Fonction d'appel bastion ────────────────────────────────────────────────
bastion_osh() {
    local cmd="$*"
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} ssh -i $BASTION_KEY $BASTION_ACCOUNT@$BASTION_IP -- $cmd"
    else
        ssh -i "$BASTION_KEY" \
            -o StrictHostKeyChecking=accept-new \
            -o BatchMode=yes \
            "$BASTION_ACCOUNT@$BASTION_IP" -- $cmd
    fi
}

# ─── Résumé ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "   Setup groupe rsync-backup sur the-bastion"
echo "══════════════════════════════════════════════════"
echo ""
log "Bastion        : $BASTION_ACCOUNT@$BASTION_IP"
log "Clé admin      : $BASTION_KEY"
log "Groupe         : $GROUP_NAME"
log "srv-backup     : $SRV_BACKUP_USER@$SRV_BACKUP_IP:$SRV_BACKUP_PORT"
$DRY_RUN && warn "Mode DRY-RUN activé — aucune modification ne sera effectuée"
echo ""

# ─── Étape 1 : Création du groupe ────────────────────────────────────────────
log "Étape 1/3 : Création du groupe '$GROUP_NAME'..."
bastion_osh --osh groupCreate \
    --group "$GROUP_NAME" \
    --owner "$BASTION_ACCOUNT" \
    --algo ed25519 \
    --size 256
ok "Groupe '$GROUP_NAME' créé (ou déjà existant)"

echo ""

# ─── Étape 2 : Ajout de srv-backup comme serveur SSH ─────────────────────────
log "Étape 2/3 : Ajout de srv-backup en accès SSH standard..."
bastion_osh --osh groupAddServer \
    --group "$GROUP_NAME" \
    --host "$SRV_BACKUP_IP" \
    --user "$SRV_BACKUP_USER" \
    --port "$SRV_BACKUP_PORT" \
    --force
ok "srv-backup ajouté en SSH ($SRV_BACKUP_USER@$SRV_BACKUP_IP:$SRV_BACKUP_PORT)"

echo ""

# ─── Étape 3 : Ajout du protocole rsync ──────────────────────────────────────
log "Étape 3/3 : Activation du protocole rsync vers srv-backup..."
bastion_osh --osh groupAddServer \
    --group "$GROUP_NAME" \
    --host "$SRV_BACKUP_IP" \
    --port "$SRV_BACKUP_PORT" \
    --protocol rsync \
    --force
ok "Protocole rsync activé vers $SRV_BACKUP_IP:$SRV_BACKUP_PORT"

echo ""

# ─── Affichage de la clé egress du groupe ────────────────────────────────────
echo "══════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}✔ Groupe '$GROUP_NAME' configuré avec succès !${NC}"
echo ""
echo -e "${YELLOW}⚠ ACTION REQUISE — Clé egress du groupe :${NC}"
echo ""
log "Récupération de la clé publique egress du groupe..."
echo ""

if ! $DRY_RUN; then
    bastion_osh --osh groupInfo --group "$GROUP_NAME" 2>/dev/null | grep -A1 "Egress" || \
    bastion_osh --osh groupInfo --group "$GROUP_NAME"
fi

echo ""
echo "┌─────────────────────────────────────────────────────────────────────┐"
echo "│  Copiez la clé publique ci-dessus et ajoutez-la sur srv-backup :    │"
echo "│                                                                     │"
echo "│  Sur srv-backup, en tant que root :                                 │"
echo "│    mkdir -p /home/$SRV_BACKUP_USER/.ssh                             │"
echo "│    echo 'CLEF_PUBLIQUE_CI_DESSUS' >> \\                              │"
echo "│      /home/$SRV_BACKUP_USER/.ssh/authorized_keys                    │"
echo "│    chown -R $SRV_BACKUP_USER: /home/$SRV_BACKUP_USER/.ssh           │"
echo "│    chmod 700 /home/$SRV_BACKUP_USER/.ssh                            │"
echo "│    chmod 600 /home/$SRV_BACKUP_USER/.ssh/authorized_keys            │"
echo "└─────────────────────────────────────────────────────────────────────┘"
echo ""
echo "Ensuite, lancez 01-create-backup-account.sh pour chaque serveur source."
echo ""
