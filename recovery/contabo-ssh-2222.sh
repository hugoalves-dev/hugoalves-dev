#!/usr/bin/env bash
# Recuperacao emergencial de SSH Debian 13 / Contabo
# Apenas restaura acesso pela porta 2222; nao modifica chaves, Docker ou bancos.
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "Execute como root: sudo bash /tmp/ssh-rescue.sh"
  exit 1
fi

dmesg -n 1 || true
stamp="$(date +%Y%m%d-%H%M%S)"
backup="/root/ssh-recovery-$stamp"
mkdir -p "$backup"
cp -a /etc/ssh/sshd_config "$backup/"
if [[ -d /etc/ssh/sshd_config.d ]]; then
  cp -a /etc/ssh/sshd_config.d "$backup/"
fi
if [[ -d /etc/systemd/system/ssh.socket.d ]]; then
  cp -a /etc/systemd/system/ssh.socket.d "$backup/"
fi
echo "Backup: $backup"

# Desfaz apenas os dois drop-ins sugeridos nesta conversa.
for f in /etc/ssh/sshd_config.d/90-dbaccess.conf /etc/ssh/sshd_config.d/90-db-tunnel.conf; do
  if [[ -f "$f" ]]; then
    mv "$f" "$backup/$(basename "$f").disabled"
  fi
done

# Garante 2222 no sshd, inclusive no modo ssh.service.
# A checagem evita adicionar linhas duplicadas em execucoes futuras.
if ! /usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" && $2=="2222" {ok=1} END {exit !ok}'; then
  sed -i '1iPort 2222' /etc/ssh/sshd_config
fi
install -d -m 0755 /run/sshd
if ! /usr/sbin/sshd -t; then
  echo "ERRO: configuracao sshd invalida. Restaurando sshd_config anterior."
  cp -a "$backup/sshd_config" /etc/ssh/sshd_config
  exit 1
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 2222/tcp
fi

# Debian 13 pode estar usando ssh.socket em vez do listener direto.
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
  mkdir -p /etc/systemd/system/ssh.socket.d
  cat > /etc/systemd/system/ssh.socket.d/99-recovery-2222.conf <<'SOCKET'
[Socket]
ListenStream=
ListenStream=2222
SOCKET
  systemctl daemon-reload
  systemctl stop ssh.service || true
  if systemctl restart ssh.socket; then
    systemctl start ssh.service || true
  else
    echo "Aviso: ssh.socket falhou; tentando ssh.service convencional."
    systemctl disable --now ssh.socket || true
    systemctl enable --now ssh.service
  fi
else
  systemctl enable ssh.service
  systemctl restart ssh.service
fi

echo
echo "===== ESTADO DO SSH ====="
systemctl --no-pager --full status ssh.service ssh.socket || true
echo
ss -lntp | grep -E ':(2222|22)[[:space:]]' || true
echo
echo "===== CONFIGURACAO EFETIVA PARA hugo ====="
/usr/sbin/sshd -T -C user=hugo,host=ssh2.hugojava.dev,addr=127.0.0.1 2>&1 | grep -E '^(port|pubkeyauthentication|passwordauthentication|authenticationmethods|allowusers|denyusers) ' || true
echo
if ss -lnt | grep -Eq ':2222[[:space:]]'; then
  echo "OK: listener na porta 2222. Teste do Windows: ssh -p 2222 hugo@ssh2.hugojava.dev"
else
  echo "FALHA: nada escutando na 2222. Consulte: journalctl -u ssh -n 50 --no-pager"
  exit 1
fi
