#!/usr/bin/env bash
# =============================================================================
# 01-create-backup-account.sh
# Crée un compte bastion pour un serveur source et l'ajoute au groupe rsync-backup
# À exécuter pour CHAQUE serveur qui doit envoyer ses backups
#
# Ce script :
#   1. Crée le compte bastion (ex: backup-zabbix)
#   2. Dépose la clé publique SSH du serveur source
#   3. Ajoute le compte au groupe rsync-backup
#
# Usage :
#   ./01-create-backup-account.sh [OPTIONS]
#
# Exemple :
#   ./01-create-backup-account.sh \
#     --bastion-ip 192.168.2.102 \
#     --bastion-account admin \
#     --bastion-key ~/.ssh/admin_bastion \
#     --account backup-zabbix \
#     --pubkey "ssh-ed25519 AAAA...== root@zabbix"
#
# Note : la clé publique est générée par setup-rsync-client.sh sur le serveur source
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
log()   { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options obligatoires :
  --bastion-ip       IP du bastion (ex: 192.168.2.102)
  --bastion-account  Compte admin sur le bastion (ex: admin)
  --bastion-key      Chemin de la clé SSH admin (ex: ~/.ssh/admin_bastion)
  --account          Nom du compte à créer (ex: backup-zabbix)
  --pubkey           Clé publique SSH du serveur source (entre guillemets)

Options facultatives :
  --group-name       Nom du groupe (défaut: rsync-backup)
  --dry-run          Affiche les commandes sans les exécuter
  --comment          Commentaire pour le compte (ex: "Zabbix LXC 103")
  -h, --help         Affiche cette aide

Conseil : générez la clé SSH sur le serveur source avec :
  ./client/setup-rsync-client.sh --server-name <nom> --print-key-only
EOF
    exit 0
}

# ─── Parse des arguments ─────────────────────────────────────────────────────
BASTION_IP=""
BASTION_ACCOUNT=""
BASTION_KEY=""
ACCOUNT=""
PUBKEY=""
COMMENT=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bastion-ip)       BASTION_IP="$2";       shift 2 ;;
        --bastion-account)  BASTION_ACCOUNT="$2";  shift 2 ;;
        --bastion-key)      BASTION_KEY="$2";      shift 2 ;;
        --account)          ACCOUNT="$2";          shift 2 ;;
        --pubkey)           PUBKEY="$2";           shift 2 ;;
        --group-name)       GROUP_NAME="$2";       shift 2 ;;
        --comment)          COMMENT="$2";          shift 2 ;;
        --dry-run)          DRY_RUN=true;          shift ;;
        -h|--help)          usage ;;
        *) error "Argument inconnu : $1" ;;
    esac
done

# ─── Validation ──────────────────────────────────────────────────────────────
[[ -z "$BASTION_IP" ]]      && error "--bastion-ip est requis"
[[ -z "$BASTION_ACCOUNT" ]] && error "--bastion-account est requis"
[[ -z "$BASTION_KEY" ]]     && error "--bastion-key est requis"
[[ -z "$ACCOUNT" ]]         && error "--account est requis"
[[ -z "$PUBKEY" ]]          && error "--pubkey est requis"

# Validation du format du nom de compte (uniquement alphanum + tirets)
if ! [[ "$ACCOUNT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "Nom de compte invalide '$ACCOUNT' — uniquement lettres, chiffres, tirets, underscores"
fi

BASTION_KEY="${BASTION_KEY/#\~/$HOME}"
[[ ! -f "$BASTION_KEY" ]] && error "Clé SSH introuvable : $BASTION_KEY"

# ─── Fonction d'appel bastion ────────────────────────────────────────────────
bastion_osh() {
    local args=("$@")
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} ssh -i $BASTION_KEY $BASTION_ACCOUNT@$BASTION_IP -- ${args[*]}"
    else
        ssh -i "$BASTION_KEY" \
            -o StrictHostKeyChecking=accept-new \
            -o BatchMode=yes \
            "$BASTION_ACCOUNT@$BASTION_IP" -- "${args[@]}"
    fi
}

# ─── Résumé ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "   Création compte bastion : $ACCOUNT"
echo "══════════════════════════════════════════════════"
echo ""
log "Bastion      : $BASTION_ACCOUNT@$BASTION_IP"
log "Clé admin    : $BASTION_KEY"
log "Compte       : $ACCOUNT"
log "Groupe cible : $GROUP_NAME"
[[ -n "$COMMENT" ]] && log "Commentaire  : $COMMENT"
log "Clé publique : ${PUBKEY:0:40}..."
$DRY_RUN && warn "Mode DRY-RUN activé — aucune modification ne sera effectuée"
echo ""

# ─── Étape 1 : Création du compte ────────────────────────────────────────────
log "Étape 1/3 : Création du compte '$ACCOUNT'..."

# Prépare les arguments optionnels
COMMENT_ARG=()
if [[ -n "$COMMENT" ]]; then
    COMMENT_ARG=(--comment "\"$COMMENT\"")
fi

bastion_osh --osh accountCreate \
    --account "$ACCOUNT" \
    --uid-auto \
    --public-key "\"$PUBKEY\"" \
    "${COMMENT_ARG[@]+"${COMMENT_ARG[@]}"}"

ok "Compte '$ACCOUNT' créé avec sa clé publique"
echo ""

# ─── Étape 2 : Ajout au groupe ───────────────────────────────────────────────
log "Étape 2/3 : Ajout de '$ACCOUNT' au groupe '$GROUP_NAME'..."
bastion_osh --osh groupAddMember \
    --group "$GROUP_NAME" \
    --account "$ACCOUNT"
ok "'$ACCOUNT' ajouté comme membre du groupe '$GROUP_NAME'"
echo ""

# ─── Étape 3 : Vérification ──────────────────────────────────────────────────
log "Étape 3/3 : Vérification des accès..."
if ! $DRY_RUN; then
    bastion_osh --osh accountInfo --account "$ACCOUNT" 2>/dev/null || true
fi

# ─── Résumé final ────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo -e "${GREEN}✔ Compte '$ACCOUNT' configuré avec succès !${NC}"
echo ""
echo "Récapitulatif :"
echo "  • Compte bastion : $ACCOUNT"
echo "  • Groupe membre  : $GROUP_NAME"
echo "  • Clé ingress    : déposée"
echo ""
echo "Le serveur source peut maintenant se connecter :"
echo ""
echo "  ssh -i /opt/backup/id_ed25519 $ACCOUNT@$BASTION_IP"
echo ""
echo "Et lancer ses rsync (syntaxe the-bastion) :"
echo ""
echo "  rsync -va \\"
echo "    --rsh \"ssh -T -i /opt/backup/id_ed25519 -o StrictHostKeyChecking=accept-new -o BatchMode=yes $ACCOUNT@$BASTION_IP -p 22 -- --osh rsync --\" \\"
echo "    /data/to/backup/ \\"
echo "    usr-rsync@<srv-backup-ip>:/backup/\$(hostname -s)/"
echo ""
echo "⚠ Ne pas oublier d'injecter la clé d'hôte de srv-backup dans le bastion (voir README)"
echo ""
