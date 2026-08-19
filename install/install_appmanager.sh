#!/bin/sh


echo "#######################################"
echo "#####  CONFIGURACAO INICIALIZADA ######"
echo "#######################################"
echo ""

echo "#### DESABILITANDO SELINUX/FIREWALLD/IPTABLES ####"
[ -f /etc/sysconfig/selinux ] && sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/sysconfig/selinux
[ -f /etc/selinux/config ] && sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

systemctl stop firewalld > /dev/null 2>&1 || true
systemctl disable firewalld > /dev/null 2>&1 || true

iptables -F  > /dev/null 2>&1 || true
ip6tables -F > /dev/null 2>&1 || true

echo "#### ALTERANDO LIMITS.CONF ####"
# Aumenta FDs/threads para host e usuario 'philips'
cat >> /etc/security/limits.conf <<'EOF'
#### ALTERACAO INSTALACAO TASY INICIO ####
*   soft   nofile    8192
*   hard   nofile    65536
*   soft   nproc     16384
*   hard   nproc     16384
*   soft   stack     10240
*   hard   stack     32768
*   soft   memlock   134217728
*   hard   memlock   134217728
#### ALTERACAO INSTALACAO TASY  FIM ####
## ALTERACAO DE OPEN FILES PHILIPS ##
philips soft nproc 32768 
philips hard nproc 32768
EOF

echo "#### ALTERANDO SYSCTL.CONF ####"
# Tunings limpos para host Docker + HAProxy/Tomcat
cat > /etc/sysctl.conf <<'EOF'
#### ALTERACAO INSTALACAO TASY  ####
# Docker/bridge e roteamento local
net.ipv4.ip_forward = 1

# Conexões e rede
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.core.optmem_max = 25165824

# Portas efêmeras
net.ipv4.ip_local_port_range = 10000 65535

# Keepalive para conexões longas (balancers, app servers)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_fin_timeout = 15

# Buffers (um conjunto único, razoável)
net.core.rmem_default = 262144
net.core.rmem_max     = 4194304
net.core.wmem_default = 262144
net.core.wmem_max     = 1048576

# FDs globais
fs.file-max = 2097152

kernel.sched_autogroup_enabled=0

# Inotify (containers que assistem arquivos/logs)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# Desabilitar IPv6 (se não utilizado)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# Swappiness e escrita
vm.swappiness = 5
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20

# Filtro de rota (modo "loose" no all ajuda em ambientes com roteamento/VRRP)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 1
#### ALTERACAO INSTALACAO TASY  FIM ####
EOF

sysctl --system > /dev/null
sysctl -p > /dev/null

echo "#### INSTALAÇÃO DE PACOTES DO SISTEMA OPERACIONAL ####"
dnf install -y liberation-fonts
dnf install -y telnet
dnf install -y tcpdump
dnf install -y zip
dnf install -y vim-enhanced
dnf install -y unzip
dnf install -y tzdata
dnf install -y chrony
dnf install -y wget
dnf install -y haproxy
dnf install -y ghostscript
dnf install -y hplip-common
dnf install -y curl
dnf install -y ntsysv
dnf install -y net-tools
dnf install -y tar
dnf install -y bind-utils
dnf install -y ftp
dnf install -y nmap-ncat
dnf install -y mlocate
dnf install -y psmisc
dnf install -y yum-utils
yum remove -y docker-ce*
yum remove -y docker-ce-cli
yum remove -y containerd.io
yum remove -y docker*
yum update -y

echo "#### CRIACAO DE USUARIO E PREPARACAO DOS DIRETORIOS ####"
# Criar grupo antes do usuário; evitar duplicidades
useradd philips
getent group philips >/dev/null || groupadd philips
id philips >/dev/null 2>&1 || useradd -g philips -s /bin/bash -d /home/philips -m philips

mkdir -p /u01
chown -R philips:philips /u01

# Senha opcional (remova se não quiser definir)
echo "philips:philips01" | chpasswd

# Sudoer (evita duplicar linha)
if ! grep -q "^philips ALL" /etc/sudoers; then
  echo "philips ALL = (ALL) ALL" >> /etc/sudoers
fi

echo "#### CONFIGURANDO LOCALTIME ####"
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime

echo "#### HISTTIMEFORMAT ####"
grep -q HISTTIMEFORMAT /home/philips/.bashrc || echo 'export HISTTIMEFORMAT="%h/%d - %H:%M:%S "' >> /home/philips/.bashrc
grep -q HISTTIMEFORMAT /root/.bashrc    || echo 'export HISTTIMEFORMAT="%h/%d - %H:%M:%S "' >> /root/.bashrc

echo "#### CRIANDO SCRIPT DE LIMPEZA DE CACHE E AGENDANDO VIA CRON ####"

# Criar diretório de scripts
mkdir -p /u01/script
#chown philips:philips /u01/script

# Criar o script cleanCache.sh
cat > /u01/script/cleanCache.sh <<'EOF'
#!/bin/bash
# Libera page cache, dentries e inodes
sync
echo 1 > /proc/sys/vm/drop_caches
echo 2 > /proc/sys/vm/drop_caches
echo 3 > /proc/sys/vm/drop_caches
# Reativa a swap
swapoff -a && swapon -a
EOF

# Ajustar permissões
chmod 755 /u01/script/cleanCache.sh
#chown philips:philips /u01/script/cleanCache.sh

# Agendar via crontab (executar a cada 3 horas)
crontab -l 2>/dev/null | grep -q "/u01/script/cleanCache.sh" || \
(crontab -l 2>/dev/null; echo "0 */3 * * * /u01/script/cleanCache.sh") | crontab -


echo "#### REPOSITORIO PHILIPS + APPMANAGER ####"
curl -k https://repo.tasy.com.br/pub/philips_repo_public.sh | bash
yum -y install philips-app-manager

service philips-app-manager restart > /dev/null 2>&1
sleep 15
service philips-app-manager restart > /dev/null 2>&1

echo "#### CONCLUIDO ####"