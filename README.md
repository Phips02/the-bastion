# the-bastion — Scripts d'administration backup

Scripts pour automatiser la mise en place d'un flux rsync sécurisé via [the-bastion (OVH)](https://github.com/ovh/the-bastion).

## Architecture

```
[srv-source-1]  ─┐
[srv-source-2]  ─┼──rsync over SSH──▶ [the-bastion] ──rsync──▶ [srv-backup]
[srv-source-N]  ─┘
 backup-<name>@bastion               groupe rsync-backup       user: usr-rsync
```

- **1 compte bastion par serveur source** : `backup-<nom-serveur>`
- **1 groupe `rsync-backup`** : contient `srv-backup` comme cible, avec le protocole rsync autorisé
- Chaque compte source est **membre** du groupe → utilise la clé egress du groupe pour joindre srv-backup
- **srv-backup ne fait confiance qu'à une seule clé** : la clé egress du groupe (récupérée à l'étape 1)

## Prérequis

- Accès admin au bastion (compte avec droits `accountCreate`, `groupCreate`)
- `srv-backup` accessible depuis le bastion en SSH (port 22 par défaut)
- Un user `usr-rsync` créé sur `srv-backup` avec son répertoire `~/.ssh/`

## Procédure manuelle sur the-bastion — Ajouter un serveur cible

> Ces commandes sont **exécutées directement sur the-bastion** (via `bssh`) pour déclarer
> un serveur de destination dans un groupe rsync existant.
>
> Remplacer : `HOST` = IP ou hostname du serveur cible, `PORT` = port SSH, `USER` = user sur le serveur cible

```bash
# Étape 1a — Accès SSH (prérequis obligatoire)
bssh --osh groupAddServer --group rsync --host HOST --port PORT --user USER

# Étape 1b — Accès rsync (même groupe = même clé egress)
bssh --osh groupAddServer --group rsync --host HOST --port PORT --protocol rsync
```

> ⚠️ Les deux commandes sont nécessaires : la 1a ouvre l'accès SSH de base, la 1b active
> le protocole rsync par-dessus. Sans la 1a, la 1b seule ne suffit pas.

## Utilisation

### Étape 1 — Setup initial (une seule fois)

```bash
./admin/00-setup-rsync-group.sh \
  --bastion-ip 192.168.2.102 \
  --bastion-account admin \
  --bastion-key ~/.ssh/admin_bastion \
  --srv-backup-ip 192.168.2.111 \
  --srv-backup-user usr-rsync \
  --srv-backup-port 22
```

→ Crée le groupe `rsync-backup`, ajoute `srv-backup` comme serveur cible (SSH + rsync)  
→ **Affiche la clé egress publique du groupe** → à déposer sur `srv-backup` dans `~usr-rsync/.ssh/authorized_keys`

### Étape 2 — Ajouter un serveur source (répéter pour chaque serveur)

```bash
./admin/01-create-backup-account.sh \
  --bastion-ip 192.168.2.102 \
  --bastion-account admin \
  --bastion-key ~/.ssh/admin_bastion \
  --account backup-zabbix \
  --pubkey "ssh-ed25519 AAAA...== root@zabbix"
```

→ Crée le compte `backup-zabbix` sur le bastion  
→ Dépose la clé publique du serveur source  
→ Ajoute le compte au groupe `rsync-backup`

### Étape 3 — Configurer le serveur source

```bash
./client/setup-rsync-client.sh \
  --server-name zabbix \
  --bastion-ip 192.168.2.102 \
  --srv-backup-ip 192.168.2.111 \
  --srv-backup-user usr-rsync \
  --backup-src /etc /var/lib/zabbix
```

→ Génère une clé SSH dédiée backup sur le serveur source  
→ Affiche la clé publique (à passer à `01-create-backup-account.sh`)  
→ Crée le script de backup `/opt/backup/run-backup.sh`  
→ Installe un cron quotidien

## Commande rsync générée (pour info)

```bash
rsync -avz --delete \
  -e "ssh -i /opt/backup/id_ed25519 -o StrictHostKeyChecking=accept-new" \
  /source/path/ \
  backup-myserver@bastion_ip:srv-backup_ip@usr-rsync/backup/myserver/
```

## Structure du repo

```
the-bastion/
├── README.md
├── admin/
│   ├── 00-setup-rsync-group.sh     # Setup initial du groupe (1 fois)
│   └── 01-create-backup-account.sh # Ajouter un serveur source
└── client/
    └── setup-rsync-client.sh       # Configurer le serveur source
```
