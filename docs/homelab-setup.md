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
- Photos : hors périmètre (tu gères). Immich fait déjà des dumps de sa base dans `library/backups`, mais **sur le même SSD que les photos** : sans copie ailleurs, une panne de ce disque perd tout (photos et dumps). Prévois ta propre sauvegarde des photos.
- **Stockage** : un seul SSD NVMe de 500 Go (le HP n'a qu'un emplacement M.2) porte le système, Postgres, Vaultwarden et les photos. Les photos vont dans `/mnt/data`, simple dossier pour l'instant : le jour où un SSD est ajouté dans la baie 2,5", il suffira de le monter à cet endroit (§2.4) sans toucher à la stack.

Limite connue : un HP compromis pourrait effacer le dépôt distant (il a le droit d'écriture pour le `prune`). Voir §9.7 pour un durcissement optionnel.

**Pré-requis**
- Le HP : **EliteDesk 800 G4 Desktop Mini 65W**, i5-8500 (6 cœurs, iGPU UHD 630), 16 Go de RAM, 1 SSD NVMe 500 Go, baie 2,5" libre. BIOS famille **Q21** (livré en 02.01.06 du 05/12/2018, à mettre à jour : §2.5). Conso attendue : ~8-12 W au repos, pics à 40-65 W pendant les tâches ML d'Immich.
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
echo $ISO          # ne doit pas être vide (si Debian 14 est sortie, adapter le 13 de la regex)
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
sudo dd if="$HOME/Downloads/$ISO" of=/dev/rdisk4 bs=4m       # rdisk (raw) = bien plus rapide ; Ctrl+T affiche la progression
diskutil eject /dev/disk4
```

Si macOS affiche « Le disque n'est pas lisible par cet ordinateur » à la fin, c'est normal (système de fichiers Linux) : clique sur **Éjecter**, pas sur Initialiser.

### 1.2 Réglages BIOS du HP

Branche sur le HP : écran, clavier, **câble Ethernet** vers la box, alimentation. Allume en tapant **F10** → BIOS Setup.

1. Note la version du BIOS (*Main → System Information*). La mise à jour se fait après l'installation de Debian (§2.5), elle n'est pas bloquante.
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
7. **Partitionnement des disques** → **Manuel**. Tu vois 2 « disques » : le SSD NVMe (~500 Go, souvent nommé `nvme0n1`) et la clé USB (taille la plus petite, ne la touche pas).
   - Sélectionne le SSD 500 Go → *Créer une nouvelle table des partitions* → **GPT**.
     - Partition 1 : **512 Mo**, *Utiliser comme* : **Partition système EFI**.
     - Partition 2 : tout le reste, *Utiliser comme* : **ext4**, *Point de montage* : `/`, option `noatime`.
   - *Terminer le partitionnement et appliquer les changements* → relis le récapitulatif → Oui.
   - Pas de partition séparée pour les photos : un seul système de fichiers évite de mal deviner la répartition de l'espace. `/mnt/data` sera un simple dossier (§2.4).
   - Pas de swap nécessaire avec 16 Go (réponds Non si l'installeur s'en inquiète).
8. **Miroir de paquets** : France → `deb.debian.org`. Proxy : vide.
9. **Concours de popularité** : Non.
10. **Sélection des logiciels** : **décoche** « environnement de bureau Debian » et « GNOME » ; **coche** « serveur SSH » et « utilitaires usuels du système ». Rien d'autre.
11. **GRUB** : *Oui* pour l'installer ; périphérique : le **SSD NVMe** (en UEFI, il va dans l'ESP automatiquement).
12. *Installation terminée* : **retire la clé USB**, Continuer → le HP redémarre sur Debian. Remets l'ordre de boot sur le SSD (BIOS) si le HP retombe sur l'installateur.

> **Pas de LUKS.** Avec un seul disque, chiffrer voudrait dire chiffrer le système entier : il faudrait saisir la phrase de passe devant le HP (ou configurer un déverrouillage SSH dans l'initramfs) après chaque coupure de courant. Le vault Vaultwarden est de toute façon chiffré côté client avec ton mot de passe maître. À reconsidérer seulement si le vol du HP fait partie de ton modèle de menace.

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

#### Terminal Ghostty (Mac) : `nano`, `htop`, `less`…

Ghostty annonce `TERM=xterm-ghostty`. Si le serveur ne connaît pas ce terminal, `nano` & co échouent avec `Error opening terminal: xterm-ghostty` (ou s'affichent mal, touches Retour arrière/flèches cassées). Sur le HP :

```sh
sudo apt install -y ncurses-term       # base terminfo étendue (contient xterm-ghostty dans les versions récentes)
infocmp xterm-ghostty >/dev/null && echo OK
```

Si ça n'affiche pas `OK`, copie la définition depuis le Mac (**à lancer dans un onglet Ghostty**, qui fournit le fichier), installée pour tout le système pour que `sudo nano` marche aussi :

```sh
HP=<user>@192.168.1.42                 # TON utilisateur Debian (§2.0, point 5) : sans "user@", ssh/scp prennent ton nom d'utilisateur Mac
infocmp -x xterm-ghostty > /tmp/ghostty.ti && scp /tmp/ghostty.ti $HP:/tmp/
ssh -t $HP 'sudo tic -x -o /usr/share/terminfo /tmp/ghostty.ti && rm /tmp/ghostty.ti'
```

(Une fois `~/.ssh/config` rempli au §2.2, `homelab` suffit à la place de `user@ip`.)

Optionnel, côté Mac, pour que ce soit automatique sur tous les serveurs (VPS compris), dans `~/.config/ghostty/config` :

```
shell-integration-features = ssh-terminfo,ssh-env
```

(Ghostty ≥ 1.2 : installe la définition au premier `ssh`, ou retombe sur `xterm-256color` s'il ne peut pas.) Dépannage express sans rien installer : `TERM=xterm-256color nano fichier`.

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
sudo ufw allow in on tailscale0 to any port 22 proto tcp       # SSH depuis le tailnet (une fois Tailscale installé ; Tailscale accepte déjà ce trafic avant ufw, le filtrage réel = les ACL §4.1)
sudo ufw enable

sudo dpkg-reconfigure -plow unattended-upgrades                # répondre Oui
```

`unattended-upgrades` applique les correctifs de sécurité Debian. Active aussi le reboot auto la nuit si noyau mis à jour : dans `/etc/apt/apt.conf.d/50unattended-upgrades`, décommente et règle
`Unattended-Upgrade::Automatic-Reboot "true";` et `Unattended-Upgrade::Automatic-Reboot-Time "04:30";`.

> `unattended-upgrades` ne couvre que les dépôts Debian. Les paquets Docker et Tailscale (dépôts tiers, §3 et §4) ne sont **pas** mis à jour automatiquement : fais un `sudo apt update && sudo apt upgrade` environ une fois par mois (voir §10).

### 2.4 Dossier des photos (et futur SSD 2,5")

Pour l'instant les photos restent sur le SSD système, dans un simple dossier :

```sh
sudo mkdir -p /mnt/data
df -h /                          # espace libre : environ 450 Go utilisables au total
```

Surveille l'espace (§10) : si `/` se remplit, Postgres et Vaultwarden plantent aussi, pas seulement Immich. Dans Immich (*Administration → Utilisateurs → modifier*), tu peux fixer un quota de stockage par utilisateur pour garder une marge.

**Plus tard : ajout d'un SSD dans la baie 2,5" (SATA).** Deux usages possibles :
- **Copie de sauvegarde des photos** (recommandé) : les photos restent sur le NVMe, le SSD 2,5" reçoit une copie (`rsync` / `restic` nocturne). Une panne d'un seul disque ne perd plus rien. Monte-le alors ailleurs, par ex. `/mnt/backup`.
- **Plus de place** : il devient le stockage des photos, monté sur `/mnt/data`. Migration :

```sh
cd /opt/homelab/infra/homelab && docker compose stop immich-server immich-machine-learning
sudo mkfs.ext4 -m 1 -L data /dev/sdX1        # ⚠️ vérifie le disque avec lsblk ; partition GPT créée avant (fdisk/gdisk)
sudo mkdir -p /mnt/new && sudo mount /dev/sdX1 /mnt/new && sudo rsync -aHAX --info=progress2 /mnt/data/ /mnt/new/ && sudo umount /mnt/new
sudo mv /mnt/data /mnt/data.old && sudo mkdir /mnt/data
echo "UUID=$(sudo blkid -s UUID -o value /dev/sdX1)  /mnt/data  ext4  defaults,noatime  0 2" | sudo tee -a /etc/fstab
sudo chattr +i /mnt/data && sudo mount -a && df -h /mnt/data    # chattr : garde-fou si le disque ne montait pas au boot
docker compose up -d                          # vérifie Immich, puis supprime /mnt/data.old
```

Le `chattr +i` rend le dossier de montage non modifiable tant que rien n'est monté dessus : si le SSD ne montait pas, Immich échouerait au lieu de remplir silencieusement le disque système.

### 2.5 Mettre à jour le BIOS HP

Le BIOS d'origine (02.01.06, 2018) n'a pas les correctifs de sécurité Intel publiés depuis (Spectre/Meltdown, Intel ME, etc.). À faire une fois Debian installé, **devant le HP** (écran + clavier), câble Ethernet branché. HP Sure Start garde une copie de secours du BIOS, mais ne coupe pas le courant pendant la mise à jour.

**Méthode A : par le réseau, depuis le BIOS** (la plus simple, à essayer d'abord)

1. Redémarre en tapant **F10**.
2. *Main → Update System BIOS* → **Check HP.com for BIOS Updates** (ou *Update BIOS via Network*).
3. Si une version plus récente est proposée : *Accept* → la machine redémarre plusieurs fois, ne touche à rien (écran noir et ventilateur fort quelques minutes, normal).

Si le BIOS ne trouve rien ou n'arrive pas à joindre HP (fréquent sur un BIOS ancien), passe à la méthode B.

**Méthode B : clé USB préparée sur le Mac**

1. Sur le site d'assistance HP, cherche **EliteDesk 800 G4 Desktop Mini** → *Logiciels et pilotes* → *BIOS* → télécharge la dernière **« HP Business Desktop Q21 System BIOS »** (fichier `spXXXXXX.exe`). Note la version annoncée.
2. Extrais-le (c'est une archive auto-extractible Windows) :

   ```sh
   brew install sevenzip
   cd ~/Downloads && 7zz x spXXXXXX.exe -osp-bios
   find sp-bios -iname 'Q21_*.bin'               # ex. sp-bios/.../Q21_022xxx.bin
   ```

3. Formate une clé en FAT32. La clé Debian peut resservir (Debian est installé) : **ça l'efface**, vérifie le numéro avec `diskutil list external`. Le BIOS cherche un fichier nommé **`firmware.bin`** dans **`EFI/HP/DEVFW/`** ou **`HP/DEVFW/`** (cf. `Bios Flash.htm` du Softpaq). Un `Q21_*.bin` placé ailleurs ou sous son nom d’origine peut être refusé (« invalid bios image »).

   ```sh
   diskutil eraseDisk FAT32 HPBIOS MBRFormat /dev/disk4
   V=/Volumes/HPBIOS; BIN=$(find sp-bios -iname 'Q21_*.bin' | head -1); ls -la "$BIN"    # ~28 Mo attendus
   mkdir -p $V/EFI/HP/DEVFW $V/HP/DEVFW
   cp "$BIN" $V/EFI/HP/DEVFW/firmware.bin && cp "$BIN" $V/HP/DEVFW/firmware.bin
   find $V -name '._*' -delete 2>/dev/null           # fichiers cachés ajoutés par macOS
   diskutil eject /dev/disk4
   ```

4. Branche la clé sur le HP (port arrière), allume en tapant **Échap** → **Update System and Supported Device Firmware** (ou **F10** → *Main → Update System BIOS* → *Update System and Supported Device Firmware Using Local Media*) → *Accept*. Laisse-le redémarrer seul.

**Après la mise à jour**

- **F10** → *Main → System Information* : vérifie la nouvelle version.
- Revérifie les réglages du §1.2 (*After Power Loss : Power On*, UEFI, ordre de boot sur le NVMe), une mise à jour peut les réinitialiser.
- Démarre Debian, puis `ssh homelab` pour confirmer que tout répond.

Ensuite : vérifier une fois par an s'il y a un nouveau BIOS (voir §10).

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
# la commande affiche "To authenticate, visit: https://login.tailscale.com/a/..." et ATTEND :
# ouvre cette URL sur le Mac, connecte-toi, valide (et approuve l'appareil si Device approval est actif) → la main revient
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

> Ce clone est **pour le HP** (qui n'a pas encore le repo). Le VPS a déjà le sien, dans `~/qui-est-ce_infra` : on n'y clone rien, on y fait seulement `git pull` (§6, §9.1).

```sh
sudo install -d -o $USER -g $USER /opt/homelab
git clone <url-de-ce-repo> /opt/homelab/infra          # ou clone via une deploy key en lecture seule si le repo est privé
cd /opt/homelab/infra/homelab
cp .env.example .env && chmod 600 .env
```

Édite `.env` :
- `DB_PASSWORD` : `openssl rand -hex 24`
- `VW_DOMAIN` : `https://vault.lepgu.fr`
- `VW_SIGNUPS_ALLOWED=true` **temporairement** (refermé au §5.1, avant toute exposition publique)
- `IMMICH_TRUSTED_PROXIES=127.0.0.1,::1` (déjà dans l'exemple) : `tailscale serve` relaie depuis localhost ; Immich lit ainsi l'IP réelle des clients (en-tête `X-Forwarded-For` posé par Caddy) au lieu de `127.0.0.1`.
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

### 5.1 Créer les comptes AVANT d'exposer au public

Tant que le DNS et Caddy (§6) ne sont pas en place, personne d'autre ne peut atteindre ces services. C'est le bon moment pour créer les comptes : sinon le premier visiteur d'Immich devient administrateur, et les inscriptions Vaultwarden sont ouvertes à tout Internet.

Depuis le Mac, ouvre un tunnel SSH (laisse-le tourner) :

```sh
ssh -L 2283:localhost:2283 -L 8222:localhost:8222 homelab
```

- **Immich** : ouvre <http://localhost:2283>, crée le compte admin (voir §7.1), puis le 2ᵉ utilisateur.
- **Vaultwarden** : le coffre web exige du **HTTPS** (`http://localhost` donne « Insecure URL not allowed »). On l'expose temporairement en HTTPS **sur le tailnet seulement**, avec un certificat `*.ts.net` :
  1. Console Tailscale → <https://login.tailscale.com/admin/dns> : active **MagicDNS** et **HTTPS Certificates**.
  2. ACL (<https://login.tailscale.com/admin/acls/file>) : ajoute temporairement `8443` à la règle `autogroup:member` → `tag:homelab:22,2283,8222,8443`.
  3. Sur le HP (`<tailnet>` = le nom affiché par `tailscale status`, ex. `tailcc4b0a`) :

     ```sh
     sudo tailscale serve --bg --https=8443 http://localhost:8222
     cd /opt/homelab/infra/homelab
     sed -i 's|^VW_DOMAIN=.*|VW_DOMAIN=https://homelab.<tailnet>.ts.net:8443|' .env
     docker compose up -d vaultwarden
     ```

  4. Ouvre `https://homelab.<tailnet>.ts.net:8443` (Tailscale connecté) : chaque utilisateur crée son compte avec un mot de passe maître long (§7.2). Ne configure pas encore l'extension / les apps (elles pointeront sur `https://vault.lepgu.fr`), et attends le domaine définitif pour une 2FA **passkey/YubiKey** (liée au nom de domaine ; le TOTP, lui, peut se faire tout de suite).

Puis **remets tout en place et referme les inscriptions** :

```sh
cd /opt/homelab/infra/homelab
sed -i 's|^VW_DOMAIN=.*|VW_DOMAIN=https://vault.lepgu.fr|; s/^VW_SIGNUPS_ALLOWED=.*/VW_SIGNUPS_ALLOWED=false/' .env
docker compose up -d vaultwarden
sudo tailscale serve --https=8443 off
tailscale serve status                     # il ne reste que 2283 et 8222
grep -E 'VW_DOMAIN|SIGNUPS' .env
```

Et retire `,8443` des ACL Tailscale.

## 6. Côté VPS : DNS + Caddy

1. **DNS chez OVH** : `photos.lepgu.fr` et `vault.lepgu.fr` doivent pointer vers l'**IP publique du VPS** (comme `qui-est-qui.lepgu.fr`). Rien à faire sur ta box.

   a. Récupère l'IP du VPS (sur le VPS) :

      ```sh
      curl -4 -s https://ifconfig.me ; echo      # IPv4, ex. 51.x.y.z
      curl -6 -s https://ifconfig.me ; echo      # IPv6 si le VPS en a une (sinon erreur : normal)
      ```

      Ou dans l'espace client OVH : *Bare Metal Cloud → VPS → ton VPS → Accueil → IPv4 / IPv6*. Compare avec l'existant : `dig +short qui-est-qui.lepgu.fr` doit donner la même IPv4.

   b. Espace client OVH (<https://www.ovh.com/manager/>) → **Web Cloud → Noms de domaine → `lepgu.fr` → onglet Zone DNS**.

   c. **Ajouter une entrée** → type **A** :
      - *Sous-domaine* : `photos` (le champ affiche déjà `.lepgu.fr` à droite : ne tape que `photos`)
      - *Cible* : l'IPv4 du VPS
      - *TTL* : par défaut (ou 3600)
      → Suivant → Valider. Recommence avec le sous-domaine **`vault`**.

   d. Si le VPS a une IPv6 **et** que `qui-est-qui` a déjà une entrée `AAAA` : ajoute aussi deux entrées **AAAA** (`photos`, `vault`) vers l'IPv6. Sinon n'en mets pas : une AAAA vers une IPv6 qui ne répond pas casse l'accès depuis les réseaux IPv6 (beaucoup de mobiles).

   e. Vérifie dans la liste de la zone :
      - pas d'autre entrée `photos` ou `vault` (CNAME, ancienne A…) ni de redirection OVH sur ces noms : supprime-les ;
      - s'il existe une entrée **CAA**, elle doit autoriser `letsencrypt.org` (sinon Caddy n'obtiendra pas de certificat).

   f. Attends la propagation (quelques minutes, parfois jusqu'à l'expiration du TTL), puis depuis le Mac :

      ```sh
      dig +short photos.lepgu.fr @1.1.1.1      # doit afficher l'IP du VPS
      dig +short vault.lepgu.fr @1.1.1.1
      ```

      Ne passe à l'étape 3 qu'une fois ces deux réponses correctes : sinon Let's Encrypt échoue (Caddy réessaie tout seul, mais avec un délai croissant).

2. Sur le VPS, dans le repo déjà cloné (`cd ~/qui-est-ce_infra`) : ajoute dans `.env` :
   ```
   HOMELAB_TAILNET_IP=100.x.y.z     # IP du HP notée au §4.3
   KC_ADMIN_ALLOWED_IP=<IP publique de ta box>   # seule IP autorisée sur la console admin Keycloak ; absente = /admin fermé
   ```
3. Déploie :
   ```sh
   git pull
   docker compose up -d caddy
   docker compose logs -f caddy      # attends l'obtention des certificats Let's Encrypt
   ```
4. Test depuis le conteneur Caddy, puis depuis l'extérieur :
   ```sh
   docker compose exec caddy sh -c 'wget -qO- http://$HOMELAB_TAILNET_IP:8222/alive'   # variable résolue DANS le conteneur
   curl -I https://photos.lepgu.fr
   curl -I https://vault.lepgu.fr
   ```
   Si le premier test timeout : `tailscale status` sur les deux machines, vérifie les ACL, et sur le VPS que le pare-feu autorise le forwarding depuis le réseau Docker vers `tailscale0`. (Le VPS est sous **Fedora** : pare-feu `firewalld`. Si le forwarding est bloqué, mets l'interface Tailscale dans la zone de confiance : `sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 && sudo firewall-cmd --reload` ; le filtrage réel reste assuré par les ACL Tailscale. Essaie d'abord sans : c'est souvent inutile.)

## 7. Configuration des applications

### 7.1 Immich (<https://photos.lepgu.fr>)

1. Premier visiteur = administrateur : le compte admin a dû être créé au §5.1, **avant** l'exposition publique (mot de passe fort, gestionnaire de mots de passe). Si ce n'est pas fait, fais-le via le tunnel SSH du §5.1, pas via le domaine public.
2. *Administration → Utilisateurs* : crée le 2ᵉ utilisateur (Immich n'a pas d'inscription ouverte : seul l'admin crée des comptes).
3. *Administration → Paramètres* : active les dumps de base (par défaut quotidien), choisis ton template de stockage si tu veux des chemins lisibles.
4. Pour le compte du quotidien, utilise un compte non-admin et réserve l'admin aux tâches de gestion.
5. App mobile : URL du serveur `https://photos.lepgu.fr`, active la sauvegarde en arrière-plan.
6. Immich n'a pas de protection anti-bruteforce native : utilise des mots de passe longs et uniques. (Si tu veux aller plus loin, CrowdSec côté VPS lisant les logs Caddy.)
7. Avec 16 Go de RAM et un i5, le machine learning (reconnaissance faciale, recherche) tourne sans accélération matérielle : l'indexation initiale peut prendre plusieurs heures, c'est normal. Pour l'accélération du transcodage vidéo (Quick Sync), voir §12.5.

### 7.2 Vaultwarden (<https://vault.lepgu.fr>)

1. Les comptes sont créés au §5.1 (tunnel SSH, `VW_SIGNUPS_ALLOWED=true`), chaque utilisateur avec un **mot de passe maître long (phrase de passe)**.
2. Vérifie que les inscriptions sont bien refermées (`grep SIGNUPS /opt/homelab/infra/homelab/.env` doit donner `false`, sinon refais la commande du §5.1).
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
3. Il **invite** l'autre par son adresse e-mail (un invité peut s'inscrire même si `SIGNUPS_ALLOWED=false` ; si son compte existe déjà, il voit simplement l'invitation) ; l'invité accepte, puis le propriétaire **confirme** le membre (étape qui échange les clés de chiffrement).
4. Les éléments à partager sont déplacés vers la collection ; le reste demeure privé dans chaque coffre personnel.

> Invitations sans e-mail : sans SMTP configuré, Vaultwarden n'envoie pas de mail d'invitation. L'invité n'a pas besoin du lien : il ouvre simplement l'application avec son compte et voit l'invitation en attente. Avec `SIGNUPS_ALLOWED=false` et `INVITATIONS_ALLOWED=true` (la config fournie), personne ne peut s'inscrire seul, mais les administrateurs d'une organisation, donc vous deux, peuvent inviter.

## 8. Vérifications de sécurité

Depuis l'extérieur (4G, pas ton wifi) :

```sh
nmap -Pn <IP_publique_de_ta_box>          # tout doit être closed/filtered
curl -I https://vault.lepgu.fr/admin      # 403
```

Sur le HP : `sudo ss -tlnp` doit montrer 2283 et 8222 liés à `127.0.0.1`, jamais à `0.0.0.0`. (Le `tailscale serve` passe par tailscaled et peut ne pas apparaître dans `ss` : le vrai test est `curl http://<ip-tailnet-HP>:8222/alive` depuis le VPS.)

## 9. Backup quotidien chiffré du vault vers le VPS

### 9.1 Compte restreint sur le VPS

```sh
cd ~/qui-est-ce_infra && git pull                                      # le repo déjà présent sur le VPS
sudo useradd --system --user-group --home-dir /srv/backups/vwbackup --no-create-home --shell /usr/sbin/nologin vwbackup   # VPS Fedora : useradd (pas l'adduser de Debian)
sudo install -d -m 755 -o root -g root /srv/backups/vwbackup           # le chroot DOIT appartenir à root
sudo install -d -m 700 -o vwbackup -g vwbackup /srv/backups/vwbackup/repo
sudo install -d -m 755 /etc/ssh/authorized_keys
sudo cp homelab/vps/sshd-vwbackup.conf /etc/ssh/sshd_config.d/50-vwbackup.conf
sudo restorecon -Rv /etc/ssh /srv/backups                                # SELinux (Fedora) : contextes par défaut
sudo sshd -t && sudo systemctl reload sshd                               # sur Fedora le service s'appelle sshd
```

> Vérifie aussi `stat -c '%A %U:%G' /` : il faut `drwxr-xr-x root:root`. Sur l'image OVH ce n'était pas le cas, et sshd (`StrictModes`) refusait alors la clé de `vwbackup` (§11). Correction : `sudo chown root:root / && sudo chmod 755 /`.
>
> Vérifie que `/etc/ssh/sshd_config` contient bien `Include /etc/ssh/sshd_config.d/*.conf` (par défaut sur Fedora comme sur Debian/Ubuntu).

### 9.2 Clé SSH dédiée (sur le HP)

```sh
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/vps-backup -C homelab-backup
sudo cat /root/.ssh/vps-backup.pub
```

Depuis le Mac, transfère la clé publique du HP vers le VPS **avec restriction d'IP source** (plage Tailscale) :

```sh
ssh -t homelab 'sudo install -m 644 -o "$USER" /root/.ssh/vps-backup.pub /tmp/'      # -t : pour que sudo puisse demander ton mot de passe
scp homelab:/tmp/vps-backup.pub /tmp/ && ssh homelab 'rm /tmp/vps-backup.pub'
cat /tmp/vps-backup.pub                                                  # une ligne "ssh-ed25519 AAAA... homelab-backup"
printf 'from="100.64.0.0/10",restrict %s\n' "$(cat /tmp/vps-backup.pub)" > /tmp/vwbackup.authkeys
scp /tmp/vwbackup.authkeys vps:/tmp/
ssh -t vps 'sudo install -m 644 -o root -g root /tmp/vwbackup.authkeys /etc/ssh/authorized_keys/vwbackup && rm /tmp/vwbackup.authkeys'
rm /tmp/vps-backup.pub /tmp/vwbackup.authkeys
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
sudo sftp vps-backup       # accepte l'empreinte du serveur ; doit ouvrir un prompt sftp>, tape `bye` (avec `ssh` au lieu de `sftp` : « This service allows sftp connections only », c'est normal)
```

### 9.3 Initialiser le dépôt restic (sur le HP)

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
>
> Garde aussi une copie hors du HP de `homelab/.env` (mot de passe Postgres d'Immich, versions) : le backup ne la contient pas.

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
sudo journalctl -u vaultwarden-backup.service -n 30 --no-pager     # sudo : sinon « No entries »
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
| OS HP | auto (Debian) | `unattended-upgrades` |
| OS VPS (Fedora 43) | mensuel, ou auto via `dnf5-automatic` | `sudo dnf upgrade --refresh` ; une nouvelle version de Fedora sort tous les 6 mois (support ~13 mois) : `sudo dnf system-upgrade` au moins une fois par an |
| Docker, Tailscale sur le HP (dépôts tiers) | mensuel | `sudo apt update && sudo apt upgrade` (sur le VPS, couverts par `dnf upgrade`) |
| Vaultwarden | dès qu'une release sort (c'est un gestionnaire de mots de passe) | changer `VAULTWARDEN_VERSION` dans `.env` puis `docker compose pull && docker compose up -d vaultwarden`. Releases : <https://github.com/dani-garcia/vaultwarden/releases> |
| Immich | ~mensuel, **lire les notes de release** | `IMMICH_VERSION=v3` suit la branche majeure ; `docker compose pull && docker compose up -d`. Pour une majeure (v4), resynchroniser `homelab/docker-compose.yml` avec la release officielle. |
| Beszel (monitoring) | ~mensuel | `BESZEL_VERSION` dans `homelab/monitoring/.env` (et l'agent du VPS), puis `docker compose pull && docker compose up -d` (§14.5) |
| Test de restauration | tous les 3 mois | §9.6 |
| Espace disque | mensuel | `df -h`, `docker system prune -f` |
| BIOS HP | annuel | page support HP du 800 G4 Mini, BIOS Q21 ; procédure §2.5 |

## 11. Dépannage

- `tailscale status` sur le HP et le VPS : les deux doivent être `active`/`direct` ou `relay`.
- 502 sur un domaine : le HP est éteint, ou `tailscale serve status` vide (refaire §4.4), ou conteneur down (`docker compose ps`).
- Vaultwarden en boucle de redémarrage avec `Permission denied` : le dossier de données n'appartient pas au uid du `user:` du compose.
- Backup en échec : `sudo journalctl -u vaultwarden-backup.service`. Cause fréquente : empreinte SSH non acceptée (refaire `sudo sftp vps-backup`) ou clé absente de `/etc/ssh/authorized_keys/vwbackup`.
- `sudo sftp vps-backup` → `Permission denied (publickey)` alors que la clé et la config sont bonnes : passe sshd du VPS en `LogLevel DEBUG1` et relis `journalctl -u sshd`. Si on y voit `bad ownership or modes for directory /`, la racine du VPS n'est pas en `755 root:root` (vu sur l'image OVH) : `sudo chown root:root / && sudo chmod 755 /`. `StrictModes` vérifie tout le chemin de `/etc/ssh/authorized_keys/vwbackup`, racine comprise.
- Certificat non émis : DNS pas encore propagé, ou ports 80/443 du VPS fermés.

## 12. Optimisation de la consommation (optionnel)

Point de départ réaliste pour le 800 G4 Mini (i5-8500) : **~8-12 W au repos**, pics à 40-65 W pendant le ML d'Immich ou un transcodage. Les réglages ci-dessous visent surtout le repos (≈ 95 % du temps) ; gain total typique : 2 à 4 W. Fais-les **un par un en mesurant**, pour garder ceux qui servent.

### 12.1 Mesurer d'abord

- Une **prise wattmètre** (~10-15 €) est la seule mesure fiable de la machine entière. Note la conso au repos avant de toucher à quoi que ce soit.
- Côté logiciel :

```sh
sudo apt install -y powertop lm-sensors linux-cpupower
sudo powertop                    # onglet "Idle stats" : le CPU doit passer l'essentiel du temps en C6/C7+ (Package)
sensors                          # températures CPU (30-45 °C au repos = bien ; > 90 °C en charge = revoir pâte thermique / poussière)
sudo smartctl -a /dev/nvme0n1 | grep -i temp
```

Si le CPU ne descend jamais sous C2/C3 en « Package », un périphérique empêche la mise en veille : c'est là que se trouvent les vrais gains (voir 12.2 et 12.3).

### 12.2 BIOS (F10)

Noms indicatifs, ils varient selon la version :

- **Advanced → Power Management Options** : *Runtime Power Management* et *Extended Idle Power States* **activés** (ce sont les états C profonds du CPU).
- **Advanced → Built-In Device Options / Port Options** : désactive ce qui ne sert pas sur un serveur headless : **WLAN/Bluetooth** (carte Wi-Fi si présente), **audio**, **port série**, lecteurs de carte. Garde l'Ethernet et l'USB.
- Laisse *After Power Loss : Power On* (§1.2). Ne touche pas à *S5 Maximum Power Savings* : il ne concerne que la machine éteinte.

### 12.3 powertop au démarrage

`powertop --auto-tune` active toutes les économies d'énergie des périphériques (autosuspend USB, gestion d'énergie SATA/PCIe, audio…). Il faut le relancer à chaque boot :

```sh
sudo tee /etc/systemd/system/powertop.service <<'UNIT'
[Unit]
Description=powertop auto-tune

[Service]
Type=oneshot
ExecStart=/usr/sbin/powertop --auto-tune
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now powertop.service
```

Effets de bord possibles : un clavier USB qui « s'endort » (sans importance en headless) ; plus rarement l'Ethernet qui décroche. Dans ce cas, exclus la carte réseau : ajoute au service une ligne
`ExecStartPost=/bin/sh -c 'echo on > /sys/class/net/eno1/device/power/control'` (remplace `eno1` par le nom vu dans `ip -br link`).

### 12.4 CPU : préférence énergie et turbo

L'i5-8500 utilise `intel_pstate` avec gestion matérielle (HWP). On lui indique de privilégier l'économie, sans brider les performances quand il y a du travail :

```sh
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference     # en général : balance_performance
sudo tee /etc/tmpfiles.d/cpu-power.conf <<'EOF2'
w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - balance_power
EOF2
sudo systemd-tmpfiles --create /etc/tmpfiles.d/cpu-power.conf
```

Optionnel, pour **plafonner les pics** (≈ 65 W → 35-40 W, mais tâches ML et transcodages plus longs, et ça chauffe moins) : désactiver le turbo, en ajoutant au même fichier :

```
w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 1
```

Annuler : supprimer la ligne puis redémarrer.

### 12.5 Immich

- **Concurrence des tâches** (*Administration → Paramètres → Tâches*) : réduis la concurrence de *Smart Search*, *Face Detection* et *Transcodage vidéo* à 1. L'import initial de la photothèque prend plus de temps, avec des pics plus courts et moins de bruit. Une fois l'import terminé, ces tâches ne tournent que sur les nouvelles photos.
- **Transcodage matériel (Quick Sync, iGPU UHD 630)** : bien plus efficace que le CPU pour les vidéos. Ajoute au service `immich-server` de `homelab/docker-compose.yml` :

  ```yaml
      devices:
        - /dev/dri:/dev/dri
  ```

  puis `docker compose up -d immich-server`, et dans *Administration → Paramètres → Transcodage vidéo → Accélération matérielle* : **Quick Sync**. Vérifie sur une vidéo que la lecture fonctionne ; en cas de souci, repasse sur *Désactivé*.
- Les modèles ML sont déchargés de la RAM après 5 min d'inactivité par défaut (`MACHINE_LEARNING_MODEL_TTL=300`) : rien à faire.

### 12.6 Disques

- **NVMe** : la mise en veille automatique (APST) est active par défaut sous Debian. Vérification :

  ```sh
  sudo nvme get-feature /dev/nvme0 -f 0x0c -H | head -3     # "Autonomous Power State Transition Enable (APSTE): Enabled"
  ```

- **Disque dur 2,5" (si ajouté plus tard)** : un HDD qui tourne en permanence consomme ~1-2 W. S'il ne sert qu'aux sauvegardes nocturnes, mets-le en veille après 10 min :

  ```sh
  sudo apt install -y hdparm
  ls -l /dev/disk/by-id/ | grep -v part          # repère l'identifiant stable du disque
  sudo tee -a /etc/hdparm.conf <<'EOF2'
  /dev/disk/by-id/ata-<identifiant> {
      spindown_time = 120
  }
  EOF2
  ```

  (`120` = 120 × 5 s = 10 min.) Ne le fais pas si le disque sert en continu, les démarrages répétés l'usent.

### 12.7 Récapitulatif

| Réglage | Gain typique | Contrepartie |
|---|---|---|
| BIOS : périphériques inutiles off | 0,5-1 W | aucune |
| powertop auto-tune | 1-3 W au repos | rare souci USB/Ethernet |
| EPP `balance_power` | 0,5-1 W | légère latence en sortie de repos |
| Turbo off | pics -25 W | tâches lourdes plus lentes |
| Quick Sync pour Immich | gros gain pendant les transcodages | à tester |
| Veille du HDD | 1-2 W | réveil de quelques secondes |

## 13. Sécurité : modèle de menace et durcissement

### 13.1 Ce que l'architecture protège bien

- **Maison invisible** : aucun port ouvert sur la box, IP maison publiée nulle part (le HP ne fait que des connexions sortantes vers Tailscale).
- **Un seul point d'entrée public**, le VPS, en HTTPS Let's Encrypt + HSTS.
- **Services du HP liés à `127.0.0.1`**, exposés uniquement sur le tailnet par `tailscale serve` (pas de contournement de `ufw` par Docker).
- **ACL deny-by-default** : le VPS n'atteint le HP que sur 2283/8222, **pas en SSH**. VPS compromis ≠ shell sur le HP.
- **Vaultwarden chiffré de bout en bout** : base volée (HP ou backup) inutilisable sans le mot de passe maître. Inscriptions fermées, `/admin` désactivé et bloqué par Caddy, conteneur non-root sans capabilities.
- **Backup du vault chiffré sur le HP** : le VPS ne voit que des blocs chiffrés ; compte SFTP chrooté, clé limitée au tailnet.
- SSH par clé uniquement, mises à jour automatiques (HP), Secure Boot, BIOS à jour.

### 13.2 Limites connues

| # | Limite | Conséquence | Parade (§13.3) |
|---|---|---|---|
| 1 | Le VPS termine le TLS : il voit le trafic en clair | VPS compromis → photos, sessions, mots de passe Immich lisibles ; coffre web Vaultwarden falsifiable (vol du mot de passe maître) | apps natives, VPS à jour, peu de services dessus |
| 2 | Immich exposé sur Internet, sans anti-bruteforce | une faille Immich est exploitable à distance | mises à jour, mots de passe longs, 2FA… (option : fail2ban, ou Immich tailnet-only) |
| 3 | Le compte Tailscale contrôle le réseau | compte volé → ACL modifiées, machine ajoutée au tailnet | 2FA, device approval, Tailnet Lock |
| 4 | Disque du HP non chiffré | vol du HP → photos, base Vaultwarden (métadonnées, pas les secrets), mot de passe restic, clé SSH de backup | mot de passe BIOS, boot USB désactivé ; LUKS si le vol devient un risque réel |
| 5 | Le HP a le droit d'effacer le dépôt de backup | HP compromis → backups supprimables | dépôt append-only (§9.7) |
| 6 | Photos en un seul exemplaire | panne disque / ransomware / erreur = perte | disque 2,5" + copie hors site |
| 7 | Utilisateur dans le groupe `docker` | `docker` = root sans mot de passe : clé SSH volée → root | retirer du groupe, `sudo docker` |
| 8 | Immich et Vaultwarden sur le même réseau Docker | un conteneur Immich compromis joint Vaultwarden en interne | réseaux séparés |
| 9 | Aucune détection d'intrusion | une compromission passerait inaperçue | monitoring (Beszel), revue des logs |

### 13.3 Actions de sécurisation

Par ordre de rentabilité. Coche au fur et à mesure.

**1. Comptes et 2FA** (15 min, le plus important)

- [ ] **2FA sur le fournisseur d'identité de Tailscale** (le compte Google / GitHub / Microsoft avec lequel tu te connectes à Tailscale) : c'est la clé maîtresse du réseau.
- [ ] Tailscale : *Settings → Device management → Device approval* activé (§4.1).
- [ ] **Tailnet Lock** (<https://login.tailscale.com/admin/settings/tailnet-lock>, doc : <https://tailscale.com/kb/1226/tailnet-lock>) : un nouvel appareil doit être signé par un de tes appareils de confiance (Mac + HP), même si le compte Tailscale ou le serveur de coordination est compromis. Garde précieusement les clés de désactivation générées.
- [ ] **Vaultwarden** : 2FA pour chaque utilisateur, codes de récupération rangés hors du coffre (§7.2). Passkey/YubiKey uniquement sur `https://vault.lepgu.fr`.
- [ ] **Immich** : mot de passe long et unique pour chaque compte ; compte admin réservé à l'administration (§7.1).
- [ ] **OVH** : 2FA sur l'espace client (le DNS est là : qui le contrôle peut rediriger `vault.lepgu.fr`).
- [ ] **GitHub** : 2FA (le repo est déployé par `git pull` sur les deux machines).

**2. Clients Vaultwarden** (5 min)

- [ ] Utilise l'**extension navigateur et les apps natives** (mobile, bureau) plutôt que le coffre web : leur code est installé localement, un VPS compromis ne peut pas le modifier pour voler le mot de passe maître.

**3. Mises à jour** (récurrent, voir §10)

- [ ] Vaultwarden dès qu'une version sort, Immich ~mensuel (notes de version), VPS Fedora mensuel (ou `dnf5-automatic`), Docker/Tailscale du HP mensuel.
- [ ] Optionnel, mises à jour auto du VPS :

  ```sh
  sudo dnf install -y dnf5-plugin-automatic
  sudo sed -i 's/^apply_updates *=.*/apply_updates = yes/' /etc/dnf/automatic.conf
  sudo systemctl enable --now dnf5-automatic.timer
  ```

**4. Retirer ton utilisateur du groupe `docker`** sur le HP (2 min)

Appartenir au groupe `docker` revient à être root sans mot de passe. Sans lui, une clé SSH volée ne suffit plus : il faut aussi ton mot de passe `sudo`.

```sh
sudo gpasswd -d $USER docker      # puis se déconnecter / reconnecter
docker ps                         # doit maintenant échouer (permission denied)
sudo docker compose ps            # à utiliser désormais (dans /opt/homelab/infra/homelab)
```

**5. Séparer les réseaux Docker** (5 min, coupure de quelques secondes : **pas pendant un import**)

Dans `homelab/docker-compose.yml`, ajoute `networks: [immich]` aux 4 services Immich (`immich-server`, `immich-machine-learning`, `redis`, `database`), `networks: [vaultwarden]` à `vaultwarden`, et en fin de fichier :

```yaml
networks:
  immich:
  vaultwarden:
```

Puis `sudo docker compose up -d` et vérifie que tout repasse `healthy`. Les ports restent liés à `127.0.0.1`, rien ne change pour `tailscale serve` ni pour Caddy.

**6. Sécurité physique du HP** (5 min, dans le BIOS F10)

- [ ] **Mot de passe administrateur BIOS** (*Security → Setup Password*), noté dans ton gestionnaire.
- [ ] **Désactiver le démarrage sur USB** et le boot réseau (*Advanced → Boot Options* : décoche *USB Storage Boot* et *Network (PXE) Boot*) : empêche de démarrer un autre système pour lire le disque. Réactive-les temporairement pour une mise à jour du BIOS (§2.5) ou une réinstallation.
- [ ] Désactiver la carte Wi-Fi/Bluetooth inutilisée (§12.2).

Limite : quelqu'un qui emporte le HP peut sortir le NVMe et le lire ailleurs. Seul un chiffrement LUKS du disque l'empêche (au prix d'une saisie de phrase de passe à chaque démarrage, §2.0).

**7. Sauvegarde des photos** (à planifier)

- [ ] Copie locale nocturne sur un disque dans la baie 2,5" (§2.4).
- [ ] Copie hors site chiffrée avec restic (Storage Box Hetzner, Backblaze B2… quelques €/To/mois), sur le modèle du §9.

**8. Backup du vault en append-only** (optionnel, §9.7)

- [ ] `rest-server --append-only` sur le VPS, joignable uniquement via le tailnet ; le HP ne peut plus qu'ajouter des snapshots. Le `forget --prune` se fait alors périodiquement depuis le Mac (machine de confiance, avec le mot de passe restic).

**9. Surveillance** (après le déploiement)

- [ ] Monitoring Beszel sur le tailnet uniquement (état des conteneurs et services, ressources, réseau, alertes) : §14.
- [ ] Check externe (healthchecks.io ou UptimeRobot) sur `https://photos.lepgu.fr` et `https://vault.lepgu.fr/alive` : alerte si le HP, le tunnel ou le VPS tombe.
- [ ] De temps en temps : `sudo journalctl -u ssh --since -7d | grep -i 'accepted\|failed'` sur le HP, et les logs Caddy du VPS.

**10. Réduire l'exposition d'Immich** (optionnel, selon ton niveau d'exigence)

- *Option forte* : Immich accessible **uniquement via Tailscale** (retirer le bloc `photos.lepgu.fr` du Caddyfile, Tailscale sur chaque téléphone ; les liens de partage publics ne marchent plus).
- *Option intermédiaire* : fail2ban ou CrowdSec sur le VPS, alimenté par les logs Caddy, qui bannit les IP qui enchaînent les échecs sur `/api/auth/login`. Attention : avec Docker, le bannissement doit passer par la chaîne `DOCKER-USER`, pas par les règles `firewalld` classiques (le trafic vers un conteneur ne passe pas par `INPUT`).

### 13.4 Vérifications régulières

| Quoi | Commande / lieu | Attendu |
|---|---|---|
| Ports de la box | `nmap -Pn <IP box>` depuis la 4G | tout `closed`/`filtered` |
| Écoute des services HP | `sudo ss -tlnp` sur le HP | 2283 et 8222 sur `127.0.0.1` uniquement |
| Admin Vaultwarden | `curl -I https://vault.lepgu.fr/admin` | `403` |
| Inscriptions Vaultwarden | `grep SIGNUPS /opt/homelab/infra/homelab/.env` | `false` |
| `tailscale serve` | `tailscale serve status` sur le HP | seulement 2283, 8222 (et 8090 si monitoring, §14) |
| ACL Tailscale | console → Access controls | identiques à `homelab/tailscale/acl.hujson` |
| Appareils du tailnet | console → Machines | aucun appareil inconnu |
| Backup du vault | `sudo journalctl -u vaultwarden-backup.service -n 20` | dernier passage OK |

## 14. Monitoring (Beszel)

Objectif : voir l'état des services, la consommation de ressources et le trafic réseau du HP (et du VPS en option), avec des alertes, sans alourdir la machine.

**Pourquoi Beszel** : un hub (interface web, base SQLite) et un agent, tous deux en Go. Il occupe **~30 Mo de RAM au total**, avec un CPU négligeable (une mesure par minute). En comparaison, Netdata prend 150-300 Mo, Prometheus + Grafana plus de 500 Mo, et Uptime Kuma ~100 Mo pour ne faire que des checks de disponibilité.

Ce qu'il affiche (historique de 1 h à 30 jours) :

| Besoin | Où dans Beszel |
|---|---|
| État des services | conteneurs Docker (état, santé, CPU/RAM/réseau de chacun) ; services systemd (`vaultwarden-backup`, `tailscaled`, `ssh`...) avec leur état `active`/`failed` |
| Consommation | CPU, charge, RAM, swap, usage et I/O disque, par machine et par conteneur (pratique pour voir le ML d'Immich) |
| Trafic réseau | débit par interface : `eno1` (LAN / Internet), `tailscale0` (tunnel, donc l'usage des apps depuis l'extérieur) |
| Matériel | températures CPU / NVMe, SMART du SSD (usure, erreurs) |

Ce qu'il ne fait pas :
- **Les watts** : rien ne remplace une prise wattmètre (§12.1).
- **T'alerter quand le HP est mort** : le hub tourne sur le HP. Le *heartbeat* (§14.3) et le check externe du §13.3 couvrent ce cas.

```
 Mac / téléphone ──tailnet HTTPS :8090──▶ HP : tailscale serve ─▶ hub 127.0.0.1:8090 ◀─socket Unix─▶ agent (HP)
                                                                    │
                                                                    ├─tailnet :45876─▶ agent (VPS, optionnel)
                                                                    └─HTTPS sortant──▶ healthchecks.io (heartbeat)
```

Aucun port n'est ouvert sur le LAN. L'interface n'est joignable que depuis tes appareils du tailnet. Les fichiers sont dans `homelab/monitoring/`, une stack séparée de celle des apps.

### 14.1 Déployer sur le HP

```sh
cd /opt/homelab/infra && git pull
cd homelab/monitoring
cp .env.example .env && chmod 600 .env
sudo install -d -m 700 /opt/homelab/beszel/hub /opt/homelab/beszel/agent /opt/homelab/beszel/socket
```

Dans `.env`, remplace `<tailnet>` dans `BESZEL_APP_URL` (le nom affiché par `tailscale status`, comme au §5.1). Puis lance **le hub seul** :

```sh
docker compose up -d beszel
```

Expose-le sur le tailnet :
1. **ACL** : recolle `homelab/tailscale/acl.hujson` dans <https://login.tailscale.com/admin/acls/file>. Il autorise `8090` pour tes appareils, et `45876` du HP vers le VPS pour le §14.4.
2. **MagicDNS + HTTPS Certificates** : déjà activés au §5.1.
3. Sur le HP :

   ```sh
   sudo tailscale serve --bg --https=8090 http://localhost:8090
   tailscale serve status        # 2283, 8222 et 8090
   ```

### 14.2 Premier lancement

1. Ouvre `https://homelab.<tailnet>.ts.net:8090` et **crée tout de suite le compte admin** : le premier visiteur le devient (seuls tes appareils du tailnet peuvent y accéder).
2. **Add System** :
   - *Name* : `homelab`
   - *Host / IP* : `/beszel_socket/beszel.sock` (l'agent et le hub communiquent par un socket Unix, sans port réseau)
   - Copie la **clé publique** dans `BESZEL_KEY` (entre guillemets) et le **token** dans `BESZEL_TOKEN`, dans `.env`. Puis valide.
3. Lance l'agent :

   ```sh
   docker compose up -d
   docker compose ps                  # beszel et beszel_agent : healthy
   docker logs beszel_agent 2>&1 | tail
   ```

   Le système passe au vert dans la minute.

Si quelque chose manque :
- **Pas de services systemd, et une erreur AppArmor dans les logs** : ajoute `- apparmor:unconfined` sous `security_opt` de `beszel-agent`, puis `docker compose up -d`.
- **Pas de SMART** : vérifie le nom du disque avec `ls /dev/nvme*`. La ligne `devices:` du compose suppose `nvme0n1`.
- **Trafic réseau parasite** (interfaces `veth`, `docker0`) : mets `BESZEL_NICS=eno1,tailscale0` dans `.env`. Le nom de l'interface LAN est donné par `ip -br link`.

### 14.3 Alertes

**Canal de notification** (*Settings → Notifications*). Le plus simple est **ntfy** : une app mobile gratuite, sans compte.

1. Génère un nom de sujet impossible à deviner, car il fait office de mot de passe : `openssl rand -hex 16`.
2. Dans l'app ntfy, abonne-toi à ce sujet.
3. Dans Beszel, ajoute l'URL `ntfy://ntfy.sh/<sujet>`.

Autres possibilités : Telegram (`telegram://<token>@telegram?chats=<id>`), ou e-mail par SMTP.

**Seuils conseillés** (icône cloche sur le système, ou *All Systems* pour tous) :

| Alerte | Seuil | Pourquoi |
|---|---|---|
| Status | down | agent ou VPS injoignable |
| CPU | > 90 % pendant 10 min | le ML d'Immich fait des pics normaux, ne pas alerter dessus |
| Memory | > 85 % pendant 10 min | |
| Disk | > 80 % | un seul SSD pour tout (photos comprises) |
| Temperature | > 85 °C pendant 5 min | poussière, ventilateur |
| Bandwidth | optionnel, ex. > 20 Mo/s pendant 10 min | envoi inhabituel vers l'extérieur |

**Heartbeat** (alerte si le HP ou le hub tombe) :
1. Sur healthchecks.io, crée un check `homelab-beszel` avec une période de 5 min et une marge (*grace*) de 5 min. Branche-le sur la même notification (ntfy, e-mail...).
2. Mets son URL de ping dans `BESZEL_HEARTBEAT_URL`, puis `docker compose up -d beszel`.

Le hub envoie un ping par minute (requête `HEAD`, aucune donnée transmise). Si les pings s'arrêtent, healthchecks.io te prévient : HP éteint, coupure de courant ou d'Internet, ou hub planté. Avec le check HTTPS externe sur `photos`/`vault` (§13.3, point 9), tu couvres aussi la panne du tunnel et celle du VPS.

### 14.4 Ajouter le VPS (optionnel)

Le hub (HP) se connecte à l'agent du VPS **par le tailnet**. L'agent écoute sur l'IP tailnet du VPS uniquement, pas sur l'IP publique. Sur le VPS :

```sh
cd ~/qui-est-ce_infra && git pull
cd homelab/vps/beszel-agent
cp .env.example .env && chmod 600 .env
# VPS_TAILNET_IP : `tailscale ip -4` ; BESZEL_KEY : la même clé publique que pour le HP
sudo firewall-cmd --get-zone-of-interface=tailscale0      # si "trusted" : pas besoin des deux lignes suivantes
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<HOMELAB_TAILNET_IP>/32" port port="45876" protocol="tcp" accept'
sudo firewall-cmd --reload
docker compose up -d
sudo ss -tlnp | grep 45876                                 # doit écouter sur 100.x.y.z uniquement
```

L'ACL du §14.1 autorise déjà `tag:homelab → tag:vps:45876`. Dans le hub, fais **Add System** avec *Name* `vps`, *Host* = l'IP tailnet du VPS, *Port* `45876`. Le token est inutile ici, car c'est le hub qui se connecte. Ensuite, active l'alerte **Status** sur ce système.

### 14.5 Entretien et sécurité

- **Mise à jour** : change `BESZEL_VERSION` (même version pour le hub et tous les agents) dans chaque `.env`, puis `docker compose pull && docker compose up -d`. Releases : <https://github.com/henrygd/beszel/releases>.
- L'agent a accès à `docker.sock`, ce qui équivaut à root sur la machine, comme tout outil de monitoring Docker. Il n'expose aucun port sur le HP (socket Unix) et n'écoute que sur le tailnet sur le VPS.
- L'interface affiche les logs des conteneurs et des services suivis : garde-la sur le tailnet, **ne l'ajoute jamais au Caddyfile**.
- La base du hub (`/opt/homelab/beszel/hub`) ne contient que des métriques : pas besoin de la sauvegarder. Si tu la perds, il suffit de recréer le compte et les systèmes.
