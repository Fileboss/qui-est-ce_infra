# Homelab : Immich + Vaultwarden sur HP EliteDesk, exposés via le VPS

Procédure complète, de l'OS vierge jusqu'au backup quotidien du vault.

## 0. Architecture et choix

```
 Téléphone / PC ──HTTPS──▶  VPS OVH (Caddy, IP publique)  ──WireGuard (Tailscale)──▶  HP EliteDesk (maison)
   photos.lepgu.fr           TLS Let's Encrypt                                          Immich      127.0.0.1:2283
   vault.lepgu.fr            (seul point exposé)                                        Vaultwarden 127.0.0.1:8222
                                                                                              │
                                                       dépôt restic chiffré (SFTP, tailnet)   │ 03h30 chaque nuit
                                                  VPS : /srv/backups/vwbackup/repo ◀───────────┘
```

- **Aucun port ouvert sur la box**, aucune IP maison publiée. Le HP ne fait que des connexions sortantes (Tailscale).
- Le VPS est le seul point d'entrée public : il termine le TLS (Caddy, déjà en place) et relaie dans le tunnel.
- Sur le HP, les conteneurs écoutent sur `127.0.0.1` uniquement. `tailscale serve` les expose **sur le tailnet seulement**. On évite ainsi le piège Docker qui contourne `ufw` quand on publie un port sur `0.0.0.0`.
- Les **ACL Tailscale** limitent les flux : VPS → HP uniquement sur 2283/8222 ; HP → VPS uniquement sur SSH (backup). Si le VPS est compromis, il n'a pas de shell sur le HP.
- **Backup du vault** : `sqlite3 .backup` (cohérent à chaud) → **restic** chiffre et déduplique **sur le HP** → dépôt envoyé en SFTP sur le VPS, dans un compte enfermé (chroot, SFTP only, uniquement depuis le tailnet). Le VPS ne voit que des blocs chiffrés.
- Photos : hors périmètre (tu gères). Immich fait déjà des dumps de sa base dans `library/backups`.

Limite connue : un HP compromis pourrait effacer le dépôt distant (il a le droit d'écriture pour le `prune`). Voir §9.7 pour un durcissement optionnel.

**Pré-requis**
- Un compte Tailscale (gratuit, jusqu'à 3 utilisateurs / 100 appareils).
- Deux sous-domaines (ci-dessous `photos.lepgu.fr` et `vault.lepgu.fr`, à adapter partout si besoin : `Caddyfile`, `homelab/.env`).
- Une clé USB ≥ 4 Go, un écran + clavier pour l'installation initiale.
- Optionnel : un compte healthchecks.io (gratuit) pour être alerté quand le backup échoue ou ne tourne plus.

---

## 1. Préparer la clé USB (depuis le Mac) et le BIOS

> Seule l'installation initiale demande d'être **physiquement devant le HP** (écran + clavier branchés dessus). Ensuite tout se fait en SSH depuis le Mac et l'écran peut être débranché.

### 1.1 Créer la clé bootable Debian

```sh
cd ~/Downloads
BASE=https://cdimage.debian.org/debian-cd/current/amd64/iso-cd
curl -LO $BASE/SHA256SUMS
ISO=$(grep -oE 'debian-13\.[0-9.]+-amd64-netinst\.iso' SHA256SUMS | head -1)   # ex. debian-13.7.0-amd64-netinst.iso
echo $ISO
curl -LO $BASE/$ISO
grep " $ISO\$" SHA256SUMS | shasum -a 256 -c -          # doit afficher : <iso>: OK
```

Vérification renforcée (optionnelle) de la signature de `SHA256SUMS` : <https://www.debian.org/CD/verify>.

Identifie la clé **sans te tromper de disque** :

```sh
diskutil list external        # repère ta clé : disque "external, physical", taille ~ celle de la clé, ex. /dev/disk4
```

Écris l'image (⚠️ efface tout le disque ciblé ; vérifie 2 fois le numéro) :

```sh
diskutil unmountDisk /dev/disk4
sudo dd if=~/Downloads/$ISO of=/dev/rdisk4 bs=4m       # rdisk (raw) = bien plus rapide ; Ctrl+T affiche la progression
diskutil eject /dev/disk4
```

Si macOS affiche « Le disque n'est pas lisible par cet ordinateur » à la fin, c'est normal (système de fichiers Linux) : clique sur **Éjecter**, pas sur Initialiser.

### 1.2 Réglages BIOS du HP

Branche sur le HP : écran, clavier, **câble Ethernet** vers la box, alimentation. Allume en tapant **F10** → BIOS Setup.

1. Mets le BIOS à jour si une version plus récente existe (site HP, ton modèle exact ; ça peut se faire plus tard depuis Debian avec `fwupd` ou la clé USB).
2. **Advanced → Boot Options** (ou *Power*) : **After Power Loss : Power On** (le serveur redémarre seul après une coupure de courant).
3. Mode **UEFI** (pas de Legacy / CSM). **Secure Boot** peut rester activé, Debian le supporte.
4. Ordre de boot : USB en premier le temps de l'installation.
5. Mets un mot de passe BIOS administrateur (note-le dans ton gestionnaire).
6. Enregistre et quitte (F10).

## 2. Installer Debian 13 (« trixie »)

Debian stable : peu de surprises, correctifs de sécurité automatiques, très léger.

### 2.0 Pas-à-pas de l'installateur

Branche la clé, allume le HP, tape **F9** (menu de boot) ou **Échap** puis choisis la clé (« UEFI USB »). Menu GRUB : **Install** (mode texte, plus simple que *Graphical install* ; les écrans sont identiques).

1. **Langue** : Français, **pays** France, **clavier** : Français (AZERTY, ou le tien).
2. **Réseau** : automatique via DHCP (Ethernet). Si l'installateur demande une interface, prends la filaire.
3. **Nom de machine** : `homelab`. **Domaine** : laisse vide.
4. **Mot de passe root** : **laisse vide** (compte root désactivé, ton utilisateur reçoit `sudo`).
5. **Nom complet / identifiant / mot de passe** de ton utilisateur. Mot de passe solide (il sert pour `sudo`). Cet utilisateur sera l'**uid 1000** attendu par la stack.
6. **Fuseau horaire** : Paris.
7. **Partitionnement des disques** → **Manuel**. Tu vois 3 « disques » : les deux SSD et éventuellement la clé (taille la plus petite, ne la touche pas). Identifie les SSD par leur taille (~256 Go et ~500 Go).
   - Sélectionne le SSD 256 Go → *Créer une nouvelle table des partitions* → **GPT**.
     - Partition 1 : **512 Mo**, *Utiliser comme* : **Partition système EFI**.
     - Partition 2 : tout le reste, *Utiliser comme* : **ext4**, *Point de montage* : `/`, option `noatime`.
   - Sélectionne le SSD 500 Go → nouvelle table **GPT** → une partition de tout l'espace, **ext4**, point de montage **`/mnt/data`**, options `noatime`. (Dans *Pourcentage de blocs réservés*, mets **1 %** : l'installeur en réserve 5 % par défaut, inutile pour des données.)
   - *Terminer le partitionnement et appliquer les changements* → relis le récapitulatif → Oui.
   - Si tu veux chiffrer le SSD 500 Go : choisis plutôt *Configurer les volumes chiffrés* (LUKS). Tu devras alors saisir la phrase de passe **à la main à chaque redémarrage** (voir note ci-dessous).
   - Pas de swap nécessaire avec 16 Go (réponds Non si l'installeur s'en inquiète).
8. **Miroir de paquets** : France → `deb.debian.org`. Proxy : vide.
9. **Concours de popularité** : Non.
10. **Sélection des logiciels** : **décoche** « environnement de bureau Debian » et « GNOME » ; **coche** « serveur SSH » et « utilitaires usuels du système ». Rien d'autre.
11. **GRUB** : *Oui* pour l'installer ; périphérique : le **SSD 256 Go** (en UEFI, il va dans l'ESP automatiquement).
12. *Installation terminée* : **retire la clé USB**, Continuer → le HP redémarre sur Debian. Remets l'ordre de boot sur le SSD (BIOS) si le HP retombe sur l'installateur.

> **LUKS ou pas ?** Chiffrer le SSD de 500 Go protège les photos en cas de vol physique, mais impose de te déplacer (ou de configurer un déverrouillage SSH dans l'initramfs) après chaque coupure de courant. Le vault Vaultwarden est de toute façon chiffré côté client avec ton mot de passe maître. Recommandation : pas de LUKS, sauf si le vol du HP est dans ton modèle de menace.

### 2.0b Trouver l'IP et passer en SSH depuis le Mac

À l'invite de connexion sur l'écran du HP, connecte-toi puis :

```sh
ip -4 -br a        # repère l'adresse de l'interface filaire, ex. 192.168.1.42
```

(ou lis-la dans la liste des appareils de ta box). Depuis ton Mac :

```sh
ssh <user>@192.168.1.42
```

À partir de là, tu peux débrancher écran et clavier du HP. **Toutes les commandes suivantes sont à taper depuis le Mac, dans cette session SSH** (sauf mention « sur le VPS »). Première chose :

```sh
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl git ufw sqlite3 restic unattended-upgrades ca-certificates
```

### 2.1 Réservation d'IP sur la box

Dans l'interface de ta box, réserve une IP fixe (bail DHCP statique) au HP à partir de l'IP relevée au §2.0b : `192.168.1.x`. Note-la.

### 2.2 SSH par clé uniquement

Depuis ton Mac :

```sh
ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@192.168.1.x    # génère la clé avant avec ssh-keygen -t ed25519 si besoin
ssh <user>@192.168.1.x                                    # vérifie que ça marche SANS mot de passe
```

Pour simplifier la suite, ajoute sur le Mac dans `~/.ssh/config` :

```
Host homelab
    HostName 192.168.1.x       # plus tard : l'IP Tailscale du HP (§4.3), pour y accéder de n'importe où
    User <user>
    IdentityFile ~/.ssh/id_ed25519

Host vps
    HostName <ip-ou-nom-du-vps>
    User <ton-user-vps>
```

Puis `ssh homelab` / `ssh vps`.

Sur le HP :

```sh
sudo tee /etc/ssh/sshd_config.d/50-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers <user>
EOF
sudo sshd -t && sudo systemctl reload ssh
```

Garde ta session ouverte et teste une seconde connexion avant de la fermer.

### 2.3 Pare-feu et mises à jour automatiques

```sh
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp    # SSH depuis le LAN
sudo ufw allow in on tailscale0 to any port 22 proto tcp       # SSH depuis le tailnet (une fois Tailscale installé)
sudo ufw enable

sudo dpkg-reconfigure -plow unattended-upgrades                # répondre Oui
```

`unattended-upgrades` applique les correctifs de sécurité Debian. Active aussi le reboot auto la nuit si noyau mis à jour : dans `/etc/apt/apt.conf.d/50unattended-upgrades`, décommente et règle
`Unattended-Upgrade::Automatic-Reboot "true";` et `Unattended-Upgrade::Automatic-Reboot-Time "04:30";`.

### 2.4 Montage du SSD de données

```sh
sudo blkid                      # repère l'UUID de la partition 500 Go
echo 'UUID=<uuid>  /mnt/data  ext4  defaults,noatime  0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/data && sudo mount -a && df -h /mnt/data
```

(Si tu as laissé l'installateur le monter, vérifie simplement `/etc/fstab`.)

## 3. Docker

Dépôt officiel Docker (les paquets Debian sont en retard) :

```sh
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER      # se déconnecter/reconnecter ensuite
```

Limite la taille des logs Docker :

```sh
echo '{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3"}}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```

## 4. Tailscale

### 4.1 ACL (une seule fois)

1. Va sur <https://login.tailscale.com/admin/acls/file>.
2. Remplace le contenu par `homelab/tailscale/acl.hujson` (dans ce repo), puis **Save**.
   - Il définit les tags `tag:vps` et `tag:homelab`, et le deny-by-default.
3. Sur <https://login.tailscale.com/admin/settings/keys> tu n'as rien à faire (on se connecte en interactif).
4. Active aussi **Settings → Device management → Device approval** si tu veux valider manuellement tout nouvel appareil (conseillé).

### 4.2 Sur le VPS

```sh
curl -fsSL https://tailscale.com/install.sh | sh        # ou ajoute le dépôt apt manuellement : https://tailscale.com/kb/1031/install-linux
sudo tailscale up --advertise-tags=tag:vps --accept-dns=false
# ouvre l'URL affichée dans un navigateur et approuve
tailscale ip -4                                         # note l'IP du VPS (100.x.y.z)
```

> Un appareil taggé n'a **pas d'expiration de clé** : le tunnel ne tombera pas au bout de 180 jours.

### 4.3 Sur le HP

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-tags=tag:homelab --accept-dns=false
tailscale ip -4                                         # <-- HOMELAB_TAILNET_IP, note-la
```

Vérifie dans <https://login.tailscale.com/admin/machines> que les deux machines sont là, avec leur tag.

### 4.4 Exposer les apps sur le tailnet (HP)

Les conteneurs n'écoutent que sur `127.0.0.1` ; `tailscale serve` les rend joignables sur l'IP tailnet du HP (et nulle part ailleurs) :

```sh
sudo tailscale serve --bg --tcp 2283 tcp://localhost:2283
sudo tailscale serve --bg --tcp 8222 tcp://localhost:8222
tailscale serve status
```

La config est persistante au reboot. Les ACL autorisent seulement le VPS (et tes appareils) à s'y connecter.

## 5. Déployer la stack sur le HP

```sh
sudo install -d -o $USER -g $USER /opt/homelab
git clone <url-de-ce-repo> /opt/homelab/infra          # ou clone via une deploy key en lecture seule si le repo est privé
cd /opt/homelab/infra/homelab
cp .env.example .env && chmod 600 .env
```

Édite `.env` :
- `DB_PASSWORD` : `openssl rand -hex 24`
- `VW_DOMAIN` : `https://vault.lepgu.fr`
- `VW_SIGNUPS_ALLOWED=true` **temporairement** (voir §7.2)
- Vérifie les chemins `UPLOAD_LOCATION` (sur `/mnt/data`) et les versions.

Crée les dossiers avec les bons propriétaires :

```sh
sudo mkdir -p /mnt/data/immich/library /opt/homelab/immich/postgres /opt/homelab/vaultwarden/data
sudo chown -R 1000:1000 /mnt/data/immich /opt/homelab/vaultwarden/data      # uid du user vaultwarden/immich = 1000 ici
# le dossier postgres est géré par l'image (laisser root)
```

> Si `id -u` ne vaut pas 1000, change la ligne `user:` du service `vaultwarden` dans `homelab/docker-compose.yml` pour correspondre.

Lance :

```sh
docker compose pull
docker compose up -d
docker compose ps          # tout doit passer en healthy
curl -s http://127.0.0.1:8222/alive ; echo
curl -s http://127.0.0.1:2283/api/server/ping ; echo
```

## 6. Côté VPS : DNS + Caddy

1. **DNS** (OVH) : enregistrements `A` (et `AAAA` si le VPS a de l'IPv6) `photos` et `vault` pointant vers l'IP publique du VPS. Rien à propos de ta box.
2. Sur le VPS, dans le repo infra : ajoute dans `.env` :
   ```
   HOMELAB_TAILNET_IP=100.x.y.z     # IP du HP notée au §4.3
   ```
3. Déploie :
   ```sh
   git pull
   docker compose up -d caddy
   docker compose logs -f caddy      # attends l'obtention des certificats Let's Encrypt
   ```
4. Test depuis le conteneur Caddy, puis depuis l'extérieur :
   ```sh
   docker compose exec caddy wget -qO- http://$HOMELAB_TAILNET_IP:8222/alive
   curl -I https://photos.lepgu.fr
   curl -I https://vault.lepgu.fr
   ```
   Si le premier test timeout : `tailscale status` sur les deux machines, vérifie les ACL, et sur le VPS que le pare-feu autorise le forwarding depuis le réseau Docker vers `tailscale0`. (`sudo ufw route allow in on br-+ out on tailscale0` si `ufw` est actif, ou tout simplement essayer d'abord sans.)

## 7. Configuration des applications

### 7.1 Immich (<https://photos.lepgu.fr>)

1. Premier visiteur = administrateur : crée **immédiatement** le compte admin (mot de passe fort, gestionnaire de mots de passe).
2. *Administration → Utilisateurs* : crée le 2ᵉ utilisateur (Immich n'a pas d'inscription ouverte : seul l'admin crée des comptes).
3. *Administration → Paramètres* : active les dumps de base (par défaut quotidien), choisis ton template de stockage si tu veux des chemins lisibles.
4. Pour le compte du quotidien, utilise un compte non-admin et réserve l'admin aux tâches de gestion.
5. App mobile : URL du serveur `https://photos.lepgu.fr`, active la sauvegarde en arrière-plan.
6. Immich n'a pas de protection anti-bruteforce native : utilise des mots de passe longs et uniques. (Si tu veux aller plus loin, CrowdSec côté VPS lisant les logs Caddy.)
7. Avec 16 Go de RAM et un i5, le machine learning (reconnaissance faciale, recherche) tourne sans accélération matérielle : l'indexation initiale peut prendre plusieurs heures, c'est normal. Pour l'accélération du transcodage vidéo, voir `hwaccel.transcoding.yml` dans la release Immich (Quick Sync).

### 7.2 Vaultwarden (<https://vault.lepgu.fr>)

1. Avec `VW_SIGNUPS_ALLOWED=true`, chaque utilisateur crée son compte avec un **mot de passe maître long (phrase de passe)**.
2. **Referme immédiatement les inscriptions** :
   ```sh
   cd /opt/homelab/infra/homelab
   sed -i 's/^VW_SIGNUPS_ALLOWED=.*/VW_SIGNUPS_ALLOWED=false/' .env
   docker compose up -d vaultwarden
   ```
3. Chacun active la **2FA** (*Paramètres → Sécurité → Authentification à deux étapes*, TOTP ou passkey/YubiKey) et télécharge ses **codes de récupération**, à ranger hors du vault.
4. Le panneau `/admin` est désactivé (pas de `ADMIN_TOKEN`) et bloqué en plus par Caddy. Si un jour tu en as besoin, génère un token argon2 (`docker run --rm -it vaultwarden/server /vaultwarden hash`), ajoute-le temporairement à l'environnement et utilise l'accès direct via le tailnet (`http://<ip-tailnet-HP>:8222/admin`), jamais via le domaine public.
5. Clients : ils pointent sur `https://vault.lepgu.fr` (champ « URL du serveur » avant la connexion).

### 7.3 Utilisation à deux

**Immich : séparé par défaut, partage à la carte**

Chaque compte a sa bibliothèque, sa synchro mobile et ses albums. Rien n'est visible par l'autre tant que vous ne partagez pas.

- **Album partagé** : dans un album, *Partager* → choisis l'autre utilisateur, en lecture seule ou en lecture/écriture. Avec l'écriture, chacun ajoute ses photos à l'album ; elles restent stockées dans la bibliothèque de leur propriétaire. Idéal pour les vacances ou les événements.
- **Partage de bibliothèque (partenaire)** : *Compte → Partage de bibliothèque / Partners*. Chacun peut voir toute la bibliothèque de l'autre dans sa timeline. Activable dans un seul sens si vous préférez.
- **Liens publics** : pour quelqu'un sans compte (mot de passe et expiration possibles). `photos.lepgu.fr` étant public, quiconque a le lien y accède depuis Internet : à utiliser avec parcimonie.
- Si un compte est supprimé, ses photos disparaissent aussi des albums partagés.

**Vaultwarden : coffres séparés, partage via une organisation**

Chaque coffre est chiffré avec son propre mot de passe maître, le serveur ne peut lire aucun des deux. Pour partager des éléments (box, abonnements, wifi) :

1. L'un de vous crée une **Organisation** (*Coffres → Nouvelle organisation*, offre gratuite suffisante en auto-hébergé).
2. Il crée une ou plusieurs **Collections** (ex. « Maison »).
3. Il **invite** l'autre par son adresse e-mail (le compte doit déjà exister) ; l'invité accepte, puis le propriétaire **confirme** le membre (étape qui échange les clés de chiffrement).
4. Les éléments à partager sont déplacés vers la collection ; le reste demeure privé dans chaque coffre personnel.

> Invitations sans e-mail : sans SMTP configuré, Vaultwarden n'envoie pas de mail d'invitation. L'invité n'a pas besoin du lien : il ouvre simplement l'application avec son compte et voit l'invitation en attente. Avec `SIGNUPS_ALLOWED=false` et `INVITATIONS_ALLOWED=true` (la config fournie), personne ne peut s'inscrire seul, mais les administrateurs d'une organisation, donc vous deux, peuvent inviter.

## 8. Vérifications de sécurité

Depuis l'extérieur (4G, pas ton wifi) :

```sh
nmap -Pn <IP_publique_de_ta_box>          # tout doit être closed/filtered
curl -I https://vault.lepgu.fr/admin      # 403
```

Sur le HP : `sudo ss -tlnp` doit montrer 2283 et 8222 liés à `127.0.0.1` (et `tailscaled` sur l'IP tailnet), pas à `0.0.0.0`.

## 9. Backup quotidien chiffré du vault vers le VPS

### 9.1 Compte restreint sur le VPS

```sh
sudo adduser --system --group --home /srv/backups/vwbackup --no-create-home --shell /usr/sbin/nologin vwbackup
sudo install -d -m 755 -o root -g root /srv/backups/vwbackup           # le chroot DOIT appartenir à root
sudo install -d -m 700 -o vwbackup -g vwbackup /srv/backups/vwbackup/repo
sudo install -d -m 755 /etc/ssh/authorized_keys
sudo cp homelab/vps/sshd-vwbackup.conf /etc/ssh/sshd_config.d/50-vwbackup.conf
sudo sshd -t && sudo systemctl reload ssh
```

> Vérifie que `/etc/ssh/sshd_config` contient bien `Include /etc/ssh/sshd_config.d/*.conf` (par défaut sur Debian/Ubuntu).

### 9.2 Clé SSH dédiée (sur le HP)

```sh
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/vps-backup -C homelab-backup
sudo cat /root/.ssh/vps-backup.pub
```

Depuis le Mac, transfère la clé publique du HP vers le VPS **avec restriction d'IP source** (plage Tailscale) :

```sh
KEY=$(ssh homelab 'sudo cat /root/.ssh/vps-backup.pub')
ssh vps "echo 'from=\"100.64.0.0/10\",restrict $KEY' | sudo tee /etc/ssh/authorized_keys/vwbackup >/dev/null && sudo chmod 644 /etc/ssh/authorized_keys/vwbackup"
```

Sur le HP, alias SSH :

```sh
sudo tee /root/.ssh/config <<'EOF'
Host vps-backup
    HostName <IP_TAILNET_DU_VPS>
    User vwbackup
    IdentityFile /root/.ssh/vps-backup
    IdentitiesOnly yes
EOF
sudo chmod 600 /root/.ssh/config
sudo ssh vps-backup        # accepte l'empreinte du serveur ; doit ouvrir un prompt sftp>, tape `bye`
```

### 9.3 Initialiser le dépôt restic

```sh
sudo install -d -m 700 /root/.config/restic
openssl rand -base64 36 | sudo tee /root/.config/restic/password >/dev/null
sudo chmod 600 /root/.config/restic/password
sudo cat /root/.config/restic/password          # <<< À COPIER HORS DU HP, voir ci-dessous
sudo install -m 600 /opt/homelab/infra/homelab/backup/vaultwarden-backup.env.example /etc/vaultwarden-backup.env
sudo editor /etc/vaultwarden-backup.env         # ajuste si besoin, ajoute HC_PING_URL si tu utilises healthchecks.io
sudo bash -c 'set -a; . /etc/vaultwarden-backup.env; restic init'
```

> ⚠️ **Mot de passe restic = seule clé de déchiffrement.** Si le HP meurt et que tu l'as perdu, les sauvegardes sont illisibles. Stocke-le **hors du HP et hors du vault lui-même** (circularité !) : papier dans un endroit sûr, et/ou un autre gestionnaire de mots de passe, et/ou ton coffre personnel chez un proche.

### 9.4 Installer le script et le timer

```sh
cd /opt/homelab/infra/homelab/backup
sudo install -m 750 vaultwarden-backup.sh /usr/local/sbin/vaultwarden-backup.sh
sudo install -m 644 vaultwarden-backup.service vaultwarden-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vaultwarden-backup.timer
systemctl list-timers vaultwarden-backup.timer
```

### 9.5 Tester immédiatement

```sh
sudo systemctl start vaultwarden-backup.service
journalctl -u vaultwarden-backup.service -n 30 --no-pager
sudo bash -c 'set -a; . /etc/vaultwarden-backup.env; restic snapshots'
```

(Healthchecks.io : crée un check avec période 1 jour + grâce 3 h, et colle l'URL dans `HC_PING_URL`.)

### 9.6 Test de restauration (à faire une fois, puis tous les quelques mois)

Idéalement depuis une autre machine (c'est ton scénario « le HP est mort ») avec `restic`, ton mot de passe restic et un accès SFTP au VPS :

```sh
export RESTIC_REPOSITORY=sftp:<user>@<vps>:/srv/backups/vwbackup/repo    # en tant qu'admin du VPS ; ou via la clé vwbackup, chemin /repo
restic snapshots
restic restore latest --target /tmp/vw-restore
sqlite3 /tmp/vw-restore/var/backups/vaultwarden-stage/db.sqlite3 'PRAGMA integrity_check; SELECT count(*) FROM users;'
```

Pour restaurer sur un nouveau serveur : recopie `db.sqlite3`, `rsa_key*`, `attachments/`, `sends/`, `config.json` dans le dossier de données Vaultwarden (propriétaire 1000:1000), démarre le conteneur, c'est tout.

### 9.7 Aller plus loin (optionnel)

- **Protéger contre un HP compromis** : remplace le SFTP par un `rest-server --append-only` sur le VPS (accessible seulement via le tailnet), et fais le `prune` depuis le VPS ou une machine de confiance. En contrepartie, le script ne peut plus faire `forget --prune` lui-même.
- **Snapshots OVH** du VPS (option payante) pour avoir un historique du dépôt.

## 10. Maintenance

| Quoi | Fréquence | Comment |
|---|---|---|
| OS HP / VPS | auto | `unattended-upgrades` |
| Vaultwarden | dès qu'une release sort (c'est un gestionnaire de mots de passe) | changer `VAULTWARDEN_VERSION` dans `.env` puis `docker compose pull && docker compose up -d vaultwarden`. Releases : <https://github.com/dani-garcia/vaultwarden/releases> |
| Immich | ~mensuel, **lire les notes de release** | `IMMICH_VERSION=v3` suit la branche majeure ; `docker compose pull && docker compose up -d`. Pour une majeure (v4), resynchroniser `homelab/docker-compose.yml` avec la release officielle. |
| Test de restauration | tous les 3 mois | §9.6 |
| Espace disque | mensuel | `df -h`, `docker system prune -f` |

## 11. Dépannage

- `tailscale status` sur le HP et le VPS : les deux doivent être `active`/`direct` ou `relay`.
- 502 sur un domaine : le HP est éteint, ou `tailscale serve status` vide (refaire §4.4), ou conteneur down (`docker compose ps`).
- Vaultwarden en boucle de redémarrage avec `Permission denied` : le dossier de données n'appartient pas au uid du `user:` du compose.
- Backup en échec : `journalctl -u vaultwarden-backup.service`. Cause fréquente : empreinte SSH non acceptée (refaire `sudo ssh vps-backup`) ou clé absente de `/etc/ssh/authorized_keys/vwbackup`.
- Certificat non émis : DNS pas encore propagé, ou ports 80/443 du VPS fermés.
