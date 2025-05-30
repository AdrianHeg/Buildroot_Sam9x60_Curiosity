#!/bin/bash
# =============================================================================
# POST-BUILD SCRIPT PARA V2G - SAM9X60 CURIOSITY
#
# UBICACIÓN EXACTA:
# $(BR2_EXTERNAL_MCHP_PATH)/board/microchip/sam9x60_curiosity/post_build_v2g.sh
#
# PERMISOS: chmod +x post_build_v2g.sh
# =============================================================================

set -e

TARGET_DIR=$1
BOARD_DIR="$(dirname $0)"

echo "=== CONFIGURANDO SISTEMA PARA V2G ==="

# Verificar que TARGET_DIR existe
if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: TARGET_DIR $TARGET_DIR no existe"
    exit 1
fi

# Crear directorios específicos para V2G
echo "Creando directorios V2G..."
mkdir -p ${TARGET_DIR}/var/log/v2g
mkdir -p ${TARGET_DIR}/var/lib/v2g
mkdir -p ${TARGET_DIR}/var/lib/v2g/pcap
mkdir -p ${TARGET_DIR}/var/lib/v2g/config
mkdir -p ${TARGET_DIR}/etc/v2g
mkdir -p ${TARGET_DIR}/opt/v2g/bin
mkdir -p ${TARGET_DIR}/opt/v2g/scripts

# Configurar permisos para captura de paquetes (mejor que sudo)
echo "Configurando permisos para captura PCAP..."
if [ -f ${TARGET_DIR}/usr/sbin/tcpdump ]; then
    chmod u+s ${TARGET_DIR}/usr/sbin/tcpdump    # SetUID para tcpdump
fi

if [ -f ${TARGET_DIR}/usr/bin/dumpcap ]; then
    chmod u+s ${TARGET_DIR}/usr/bin/dumpcap     # SetUID para dumpcap
fi

# Crear usuario v2g con permisos específicos (sin sudo)
echo "Configurando usuario v2g..."
cat >> ${TARGET_DIR}/etc/passwd << EOF
v2g:x:1000:1000:V2G Application User:/home/v2g:/bin/bash
EOF

cat >> ${TARGET_DIR}/etc/group << EOF
v2g:x:1000:
dialout:x:20:v2g
spi:x:997:v2g
netdev:x:998:v2g
EOF

# Crear directorio home para usuario v2g
mkdir -p ${TARGET_DIR}/home/v2g
chown 1000:1000 ${TARGET_DIR}/home/v2g

# Configurar interfaces de red para V2G con systemd-networkd
echo "Configurando networking para V2G..."
mkdir -p ${TARGET_DIR}/etc/systemd/network

# Configuración eth0 para V2G (IPv4 + IPv6)
cat > ${TARGET_DIR}/etc/systemd/network/10-eth0.network << EOF
[Match]
Name=eth0

[Network]
DHCP=yes
IPv6AcceptRA=yes
LinkLocalAddressing=yes
MulticastDNS=yes
LLDP=yes

[DHCPv4]
UseDNS=yes
UseNTP=yes
UseMTU=yes

[DHCPv6]
UseNTP=yes
UseDNS=yes
EOF

# Configuración para interfaces CAN (si existen)
cat > ${TARGET_DIR}/etc/systemd/network/20-can.network << EOF
[Match]
Name=can*

[CAN]
BitRate=500K
RestartSec=100ms
EOF

# Script de inicialización para V2G
cat > ${TARGET_DIR}/opt/v2g/scripts/init_v2g.sh << 'EOF'
#!/bin/bash
# Script de inicialización V2G

echo "Inicializando sistema V2G..."

# Configurar CAN interfaces si existen
for can_if in /sys/class/net/can*; do
    if [ -d "$can_if" ]; then
        can_name=$(basename $can_if)
        echo "Configurando $can_name..."
        ip link set $can_name type can bitrate 500000
        ip link set up $can_name
    fi
done

# Crear directorio para capturas PCAP con timestamp
mkdir -p /var/lib/v2g/pcap/$(date +%Y%m%d)

# Configurar logging para V2G
mkdir -p /var/log/v2g
touch /var/log/v2g/application.log
touch /var/log/v2g/network.log
touch /var/log/v2g/debug.log

echo "Sistema V2G inicializado correctamente"
EOF

chmod +x ${TARGET_DIR}/opt/v2g/scripts/init_v2g.sh

# Configurar logrotate para logs V2G
mkdir -p ${TARGET_DIR}/etc/logrotate.d
cat > ${TARGET_DIR}/etc/logrotate.d/v2g << EOF
/var/log/v2g/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 root root
    postrotate
        /bin/systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF

# Configurar rsyslog para V2G
mkdir -p ${TARGET_DIR}/etc/rsyslog.d
cat > ${TARGET_DIR}/etc/rsyslog.d/50-v2g.conf << EOF
# V2G Logging Configuration
local0.*    /var/log/v2g/application.log
local1.*    /var/log/v2g/network.log
local2.*    /var/log/v2g/debug.log

# Stop processing if matched above
local0.*    stop
local1.*    stop
local2.*    stop
EOF

# Script para captura automática de paquetes V2G
cat > ${TARGET_DIR}/opt/v2g/scripts/capture_v2g.sh << 'EOF'
#!/bin/bash
# Script de captura automática para V2G

CAPTURE_DIR="/var/lib/v2g/pcap/$(date +%Y%m%d)"
mkdir -p "$CAPTURE_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
INTERFACE=${1:-eth0}
DURATION=${2:-3600}  # 1 hora por defecto

echo "Iniciando captura V2G en $INTERFACE por $DURATION segundos..."

# Captura con filtros específicos para V2G (puertos comunes)
tcpdump -i $INTERFACE \
    -w "$CAPTURE_DIR/v2g_capture_${TIMESTAMP}.pcap" \
    -G $DURATION \
    -W 1 \
    'port 15118 or port 443 or port 80 or icmp6' \
    > /var/log/v2g/network.log 2>&1 &

echo $! > /var/run/v2g_capture.pid
echo "Captura iniciada, PID: $(cat /var/run/v2g_capture.pid)"
EOF

chmod +x ${TARGET_DIR}/opt/v2g/scripts/capture_v2g.sh

# Servicio systemd para V2G
mkdir -p ${TARGET_DIR}/etc/systemd/system
cat > ${TARGET_DIR}/etc/systemd/system/v2g-init.service << EOF
[Unit]
Description=V2G System Initialization
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/opt/v2g/scripts/init_v2g.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Habilitar el servicio V2G
mkdir -p ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/v2g-init.service \
    ${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/v2g-init.service

# Configurar udev rules para dispositivos V2G
mkdir -p ${TARGET_DIR}/etc/udev/rules.d
cat > ${TARGET_DIR}/etc/udev/rules.d/99-v2g-devices.rules << EOF
# V2G Device Rules

# SPI devices
SUBSYSTEM=="spi", GROUP="spi", MODE="0664"

# Serial devices for V2G communication
SUBSYSTEM=="tty", ATTRS{idVendor}=="1234", ATTRS{idProduct}=="5678", SYMLINK+="v2g_serial"

# CAN devices
SUBSYSTEM=="net", KERNEL=="can*", ACTION=="add", RUN+="/opt/v2g/scripts/init_v2g.sh"
EOF

# CONFIGURACIÓN ELIMINADA: sudoers (no necesario en sistema embebido)
# En sistemas embebidos es mejor usar:
# 1. SetUID bits para herramientas específicas
# 2. Grupos de usuarios con permisos específicos
# 3. Aplicaciones que corren como root cuando sea necesario

echo "=== CONFIGURACIÓN V2G COMPLETADA ==="
echo "Directorios creados:"
echo "  - /var/log/v2g (logs)"
echo "  - /var/lib/v2g (datos y configuración)"
echo "  - /opt/v2g (aplicaciones y scripts)"
echo ""
echo "Servicios configurados:"
echo "  - v2g-init.service (inicialización automática)"
echo "  - Networking con IPv4/IPv6"
echo "  - Logging con rotación automática"
echo ""
echo "Scripts disponibles:"
echo "  - /opt/v2g/scripts/init_v2g.sh"
echo "  - /opt/v2g/scripts/capture_v2g.sh"
