#!/usr/bin/env bash
[[ ! ${WARDEN_COMMAND} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!" && exit 1

if [[ ! -d "${WARDEN_SSL_DIR}/rootca" ]]; then
    mkdir -p "${WARDEN_SSL_DIR}/rootca"/{certs,crl,newcerts,private}

    touch "${WARDEN_SSL_DIR}/rootca/index.txt"
    echo 1000 > "${WARDEN_SSL_DIR}/rootca/serial"
fi

# create CA root certificate if none present
if [[ ! -f "${WARDEN_SSL_DIR}/rootca/private/ca.key.pem" ]]; then
  echo "==> Generating private key for local root certificate"
  openssl genrsa -out "${WARDEN_SSL_DIR}/rootca/private/ca.key.pem" 2048
fi

if [[ ! -f "${WARDEN_SSL_DIR}/rootca/certs/ca.cert.pem" ]]; then
  echo "==> Signing root certificate (Warden Proxy Local CA)"
  openssl req -new -x509 -days 7300 -sha256 -extensions v3_ca \
    -config "${WARDEN_DIR}/config/openssl/rootca.conf"        \
    -key "${WARDEN_SSL_DIR}/rootca/private/ca.key.pem"        \
    -out "${WARDEN_SSL_DIR}/rootca/certs/ca.cert.pem"         \
    -subj "/C=US/O=Warden Proxy Local CA"
fi

## trust root ca differently on linux-gnu than on macOS
if [[ "$OSTYPE" == "linux-gnu" ]] && [[ ! -f /etc/pki/ca-trust/source/anchors/warden-proxy-local-ca.cert.pem ]]; then
  echo "==> Trusting root certificate (requires sudo privileges)"
  sudo cp "${WARDEN_SSL_DIR}/rootca/certs/ca.cert.pem" /etc/pki/ca-trust/source/anchors/warden-proxy-local-ca.cert.pem
  sudo update-ca-trust
  sudo update-ca-trust enable
elif [[ "$OSTYPE" == "darwin"* ]] && ! security dump-trust-settings -d | grep 'Warden Proxy Local CA' >/dev/null; then
  echo "==> Trusting root certificate (requires sudo privileges)"
  sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain "${WARDEN_SSL_DIR}/rootca/certs/ca.cert.pem"
fi

if [[ ! -f "${WARDEN_SSL_DIR}/certs/warden.test.crt.pem" ]]; then
  "${WARDEN_DIR}/bin/warden" sign-certificate warden.test
fi

## configure resolver for .test domains
if [[ "$OSTYPE" == "linux-gnu" ]]; then
  if systemctl status NetworkManager | grep 'active (running)' >/dev/null \
    && ! grep '^nameserver 127.0.0.1$' /etc/resolv.conf >/dev/null
  then
    echo "==> Configuring resolver for .test domains (requires sudo privileges)"
    if ! sudo grep '^prepend domain-name-servers 127.0.0.1;$' /etc/dhcp/dhclient.conf >/dev/null 2>&1; then
      DHCLIENT_CONF=$'\n'"$(sudo cat /etc/dhcp/dhclient.conf 2>/dev/null)" || DHCLIENT_CONF=
      DHCLIENT_CONF="prepend domain-name-servers 127.0.0.1;${DHCLIENT_CONF}"
      echo "${DHCLIENT_CONF}" | sudo tee /etc/dhcp/dhclient.conf
      sudo systemctl restart NetworkManager
    fi
  fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
  if [[ ! -f /etc/resolver/test ]]; then
    echo "==> Configuring resolver for .test domains (requires sudo privileges)"
    if [[ ! -d /etc/resolver ]]; then
        sudo mkdir /etc/resolver
    fi
    echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/test >/dev/null
  fi
else
  echo -e "\033[33m==> WARNING: Use of dnsmasq is not supported on this system; entries in /etc/hosts will be required\033[0m"
fi

## generate rsa keypair for authenticating to warden sshd service
if [[ ! -f "${WARDEN_HOME_DIR}/tunnel/ssh_key" ]]; then
  echo "==> Generating rsa key pair for tunnel into sshd service"
  mkdir -p "${WARDEN_HOME_DIR}/tunnel"
  ssh-keygen -b 2048 -t rsa -f "${WARDEN_HOME_DIR}/tunnel/ssh_key" -N "" -C "user@tunnel.warden.test"
fi

## since bind mounts are native on linux to use .pub file as authorized_keys file in tunnel it must have proper perms
if [[ "$OSTYPE" == "linux-gnu" ]] && [[ "$(stat -c '%U' "${WARDEN_HOME_DIR}/tunnel/ssh_key.pub")" != "root" ]]; then
  sudo chown root:root "${WARDEN_HOME_DIR}/tunnel/ssh_key.pub"
fi

if ! grep '## WARDEN START ##' /etc/ssh/ssh_config >/dev/null; then
  echo "==> Configuring sshd tunnel in host ssh_config (requires sudo privileges)"
  cat <<-EOF | sudo tee -a /etc/ssh/ssh_config >/dev/null
		
		## WARDEN START ##
		Host tunnel.warden.test
		  HostName 127.0.0.1
		  User user
		  Port 2222
		  IdentityFile ~/.warden/tunnel/ssh_key
		## WARDEN END ##
		EOF
fi
