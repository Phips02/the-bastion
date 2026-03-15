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

## Prérequis communs

- Accès admin au bastion (compte avec droits `accountCreate`, `groupCreate`)
- `srv-backup` accessible depuis le bastion en SSH (port 22)
- Un user `usr-rsync` créé sur `srv-backup`
- `rsync` installé sur **les deux** serveurs (source ET destination)

---

## Procédure manuelle sur the-bastion — Ajouter un serveur cible

> Remplacer : `HOST` = IP ou hostname, `PORT` = port SSH, `USER` = user sur le serveur cible

```bash
# 1a — Accès SSH (prérequis obligatoire)
bssh --osh groupAddServer --group rsync-backup --host HOST --port PORT --user USER

# 1b — Accès rsync (même groupe = même clé egress)
bssh --osh groupAddServer --group rsync-backup --host HOST --port PORT --protocol rsync
```

> ⚠️ Les deux commandes sont nécessaires. Sans la 1a, la 1b seule ne suffit pas.

---

## LXC Proxmox vs VM Debian complète

| | LXC Proxmox | VM Debian (cloud image) |
|---|---|---|
| `pam_systemd` | ⚠️ **Désactiver** (timeout 25s) | ✅ Aucune action |
| `groupAddServer` sans `--force` | ⚠️ Timeout → utiliser `--force-key` | ✅ Fonctionne directement |
| Injection known_hosts bastion | Via `qm guest exec` (simple) | Via `tee` + exec séparé |
| SSH key bootstrap | `pct exec` depuis pve1 | cloud-init ou SSH direct |

---

## Utilisation

### Étape 1 — Setup initial du groupe (une seule fois)

```bash
./admin/00-setup-rsync-group.sh \
  --bastion-ip 192.168.2.102 \
  --bastion-account admin \
  --bastion-key ~/.ssh/admin_bastion \
  --srv-backup-ip <IP_SRV_BACKUP> \
  --srv-backup-user usr-rsync \
  --srv-backup-port 22
```

→ Crée le groupe `rsync-backup`, ajoute srv-backup (SSH + rsync), affiche la clé egress

### Étape 2 — Ajouter un serveur source

```bash
./admin/01-create-backup-account.sh \
  --bastion-ip 192.168.2.102 \
  --bastion-account admin \
  --bastion-key ~/.ssh/admin_bastion \
  --account backup-<nom> \
  --pubkey "ssh-ed25519 AAAA...== root@serveur"
```

### Étape 3 — Configurer le serveur source

```bash
./client/setup-rsync-client.sh \
  --server-name <nom> \
  --bastion-ip 192.168.2.102 \
  --srv-backup-ip <IP_SRV_BACKUP> \
  --backup-src "/etc /var/lib/app"
```

### Étape 4 — Injecter la clé d'hôte de srv-backup dans le bastion

> ⚠️ Étape obligatoire : `--osh rsync` tourne dans le contexte du compte `backup-<name>`
> sur le bastion, qui a son propre `known_hosts` distinct de celui utilisé par `groupAddServer`.

```bash
HOSTKEY=$(ssh-keyscan -t ed25519 <IP_SRV_BACKUP> 2>/dev/null | grep ssh-ed25519)

# Écrire le script dans la VM bastion via tee + pass-stdin
printf '#!/bin/bash\nmkdir -p /home/backup-<name>/.ssh\necho "%s" >> /home/backup-<name>/.ssh/known_hosts\necho "%s" >> /etc/ssh/ssh_known_hosts\nchown -R backup-<name>: /home/backup-<name>/.ssh\nchmod 600 /home/backup-<name>/.ssh/known_hosts\necho DONE\n' "$HOSTKEY" "$HOSTKEY" \
  | ssh root@pve1 "qm guest exec <bastion-vmid> --pass-stdin 1 -- tee /tmp/inject.sh"

# Exécuter le script dans la VM bastion
ssh root@pve1 "qm guest exec <bastion-vmid> --pass-stdin 0 -- bash /tmp/inject.sh"
```

> 💡 Répéter pour chaque nouveau compte `backup-<name>`.

---

## Prérequis srv-backup — LXC Proxmox

Si `srv-backup` est un **LXC Proxmox sous Debian**, appliquer ces fixes :

### 1. Désactiver `pam_systemd` ⚠️ (évite un timeout de 25s à chaque connexion SSH)

```bash
sed -i 's/^session.*pam_systemd.so.*$/# & # disabled: no logind in LXC/' \
  /etc/pam.d/common-session
systemctl reload ssh
```

> Sans ce fix, `groupAddServer` timeout systématiquement (exit 124). Il faut alors
> utiliser `--force-key FINGERPRINT` pour forcer l'ajout et cacher la clé d'hôte.

### 2. Installer rsync + créer usr-rsync

```bash
apt-get install -y rsync
useradd -m -s /bin/bash usr-rsync
mkdir -p /home/usr-rsync/.ssh /backup
chown -R usr-rsync: /home/usr-rsync/.ssh /backup
chmod 700 /home/usr-rsync/.ssh
```

### 3. Déposer la clé egress du groupe rsync-backup

```bash
# Clé récupérée via : ssh admin@bastion -- --osh groupInfo --group rsync-backup
echo 'from="..." ssh-ed25519 AAAA... rsync-backup@the-bastion' \
  > /home/usr-rsync/.ssh/authorized_keys
chmod 600 /home/usr-rsync/.ssh/authorized_keys
chown usr-rsync: /home/usr-rsync/.ssh/authorized_keys
```

---

## Prérequis srv-backup — VM Debian complète

Si `srv-backup` est une **VM Debian (cloud image ou installation classique)** :

### 1. Installer rsync + créer usr-rsync

```bash
apt-get install -y rsync
useradd -m -s /bin/bash usr-rsync
mkdir -p /home/usr-rsync/.ssh /backup
chown -R usr-rsync: /home/usr-rsync/.ssh /backup
chmod 700 /home/usr-rsync/.ssh
```

> ✅ **Pas de fix `pam_systemd`** : sur une VM complète, systemd-logind fonctionne
> normalement. `groupAddServer` sans `--force` passe directement.

### 2. Déposer la clé egress du groupe rsync-backup

```bash
echo 'from="..." ssh-ed25519 AAAA... rsync-backup@the-bastion' \
  > /home/usr-rsync/.ssh/authorized_keys
chmod 600 /home/usr-rsync/.ssh/authorized_keys
chown usr-rsync: /home/usr-rsync/.ssh/authorized_keys
```

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

---

## Résumé des tests réalisés

| Type | Source | Destination | Résultat |
|---|---|---|---|
| LXC → LXC | LXC 110 (test-src) | LXC 113 (test-dst) | ✅ OK |
| VM → VM | VM 114 (vm-src, Debian 13) | VM 115 (vm-dst, Debian 13) | ✅ OK |
