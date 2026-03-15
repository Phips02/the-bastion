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
- **srv-backup ne fait confiance qu'à une seule clé** : la clé egress du groupe

---

## Prérequis

- Accès admin au bastion (compte avec droits `accountCreate`, `groupCreate`)
- `srv-backup` accessible depuis le bastion en SSH (port 22 par défaut)
- Un user `usr-rsync` créé sur `srv-backup` avec son répertoire `~/.ssh/`
- `rsync` installé sur **les deux** serveurs (source ET destination)

---

## Procédure manuelle sur the-bastion — Ajouter un serveur cible

> Ces commandes sont **exécutées directement sur the-bastion** (via `bssh`) pour déclarer
> un serveur de destination dans un groupe rsync existant.
>
> Remplacer : `HOST` = IP ou hostname du serveur cible, `PORT` = port SSH, `USER` = user sur le serveur cible

```bash
# Étape 1a — Accès SSH (prérequis obligatoire)
bssh --osh groupAddServer --group rsync-backup --host HOST --port PORT --user USER

# Étape 1b — Accès rsync (même groupe = même clé egress)
bssh --osh groupAddServer --group rsync-backup --host HOST --port PORT --protocol rsync
```

> ⚠️ Les deux commandes sont nécessaires : la 1a ouvre l'accès SSH de base, la 1b active
> le protocole rsync par-dessus. Sans la 1a, la 1b seule ne suffit pas.

---

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
  --backup-src "/etc /var/lib/zabbix"
```

→ Génère une clé SSH dédiée backup sur le serveur source  
→ Affiche la clé publique (à passer à `01-create-backup-account.sh`)  
→ Crée le script de backup `/opt/backup/run-backup.sh`  
→ Installe un cron quotidien

### Étape 4 — Injecter la clé d'hôte de srv-backup dans le bastion

> Cette étape est nécessaire car `--osh rsync` tourne dans le contexte du compte
> `backup-<name>` sur le bastion, qui a son propre `known_hosts` distinct de celui
> utilisé par `groupAddServer`.

Depuis **Proxmox** (si le bastion est une VM avec `qemu-guest-agent`) :

```bash
# Récupérer la clé d'hôte de srv-backup
HOSTKEY=$(ssh-keyscan -t ed25519 <srv-backup-ip> 2>/dev/null | grep ssh-ed25519)

# L'injecter dans le known_hosts du compte backup ET dans le global
qm guest exec <bastion-vmid> --pass-stdin 0 -- bash -c "
  mkdir -p /home/backup-<name>/.ssh
  echo '$HOSTKEY' >> /home/backup-<name>/.ssh/known_hosts
  chown -R backup-<name>: /home/backup-<name>/.ssh
  chmod 600 /home/backup-<name>/.ssh/known_hosts
  echo '$HOSTKEY' >> /etc/ssh/ssh_known_hosts
"
```

> 💡 Répéter pour chaque nouveau compte `backup-<name>`.

---

## Commande rsync (syntaxe the-bastion)

> ⚠️ La syntaxe rsync via the-bastion utilise `--rsh` avec `--osh rsync --`,
> **pas** `-e "ssh ..."` classique.

```bash
rsync -va --rsh "ssh -T -i /opt/backup/id_ed25519 \
  -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes \
  backup-<name>@<bastion-ip> -p 22 -- --osh rsync --" \
  /source/path/ \
  usr-rsync@<srv-backup-ip>:/backup/<name>/
```

---

## Prérequis serveur destination (srv-backup / LXC Proxmox)

Si `srv-backup` est un **LXC Proxmox sous Debian**, appliquer ces fixes au moment du provisioning :

### 1. Désactiver `pam_systemd` (évite un timeout de 25s à chaque connexion SSH)

```bash
sed -i 's/^session.*pam_systemd.so.*$/# & # disabled: no logind in LXC/' \
  /etc/pam.d/common-session
systemctl reload ssh
```

### 2. Installer rsync

```bash
apt-get install -y rsync
```

### 3. Créer l'utilisateur `usr-rsync`

```bash
useradd -m -s /bin/bash usr-rsync
mkdir -p /home/usr-rsync/.ssh /backup
chown -R usr-rsync: /home/usr-rsync/.ssh /backup
chmod 700 /home/usr-rsync/.ssh
```

### 4. Déposer la clé egress du groupe rsync-backup

```bash
# Récupérer la clé via : ssh admin@bastion -- --osh groupInfo --group rsync-backup
echo 'from="..." ssh-ed25519 AAAA... rsync-backup@the-bastion' \
  > /home/usr-rsync/.ssh/authorized_keys
chmod 600 /home/usr-rsync/.ssh/authorized_keys
chown usr-rsync: /home/usr-rsync/.ssh/authorized_keys
```

---

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
