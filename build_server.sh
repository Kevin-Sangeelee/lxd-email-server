#!/bin/bash

. "functions"

PREREQUISITES="yes"	# Assume all ok, unless we discover otherwise

which snap >/dev/null || { echo "No snap command. Please 'sudo apt-get install snapd' first"; unset PREREQUISITES; }
which lxc >/dev/null || { echo "No lxc command. Please 'sudo snap install lxd' first"; unset PREREQUISITES; }

if [ "${PREREQUISITES}" != "yes" ]; then
    echo "Re-run this script when the listed prerequisites are done."
    exit 1
fi

if [ ! -f "config" ]; then
    echo "Copy 'config.sample' to 'config' and edit the parameters for your VPS and domain."
    echo "Re-run this script when you have done this."
    exit
fi

. "config"

WWW_FQDN="www.${DOMAIN}"
WEBMAIL_FQDN="webmail.${DOMAIN}"
MAIL_FQDN="ponder.${DOMAIN}"

HOSTS="${MAIL_FQDN} ${WEBMAIL_FQDN}"

# Stage 1 - make sure the DNS entries are correct for what we
#           are about to do.

# Check that the top level domain has an appropriate MX record

MX_HOST=$(dns_check_MX $DOMAIN)

if [ "$MX_HOST" != "${MAIL_FQDN}" ]; then
    echo "DNS Config: the top MX host for ${DOMAIN} is not ${MAIL_FQDN}"
    exit
fi

ACME_DOMAINS=''

# Certificate to include the root domain if it resolves to our public IP
if [ "$(dns_check_A ${DOMAIN})" == "${PUBLIC_IPv4}" ]; then
    ACME_DOMAINS="-d ${DOMAIN}"
fi

# Check the A records for each host we'll include in the SSL/TLS certificate.
for d in ${HOSTS}; do

    d_IP=$(dns_check_A ${d})

    if [ "${d_IP}" == "${PUBLIC_IPv4}" ]; then
        echo "Domain ${d} correctly resolves to IP ${d_IP}"
        ACME_DOMAINS="${ACME_DOMAINS} -d ${d}"
    else
        echo "Domain ${d} resolved to '${d_IP}' The declared host IP is '${PUBLIC_IPv4}'"
        exit
    fi
done

# Check that Reverse DNS is configured for the host IP
PTR_HOST=$(dns_check_PTR ${PUBLIC_IPv4})
if [ "${PTR_HOST}" != "${MAIL_FQDN}" ]; then
    echo "WARNING: the IP address ${PUBLIC_IPv4} does not resolve back to '${MAIL_FQDN}'"
    echo "Reverse DNS (aka a PTR record) is a strong indicator that you're not"
    echo "a spammer. Whoever provides your VPS should allow you to configure this."
    read -p "Press ENTER to continue, or Ctrl_C to exit. "
fi

CONTAINER_IP_NET=$(lxc network get ${LXD_NETWORK} ipv4.address)
CONTAINER_IP="${CONTAINER_IP_NET%.*/*}.20"

echo "Net is ${CONTAINER_IP_NET}"
echo "IP is  ${CONTAINER_IP}"

#exit

# Build the container and configure the network if it doesn't already exist.
if lxc ls|grep ${CONTAINER_NAME} >/dev/null; then
    echo "Container '${CONTAINER_NAME}' exists"
else
    echo "Creating container '${CONTAINER_NAME}'"
    lxc init images:debian/10 ${CONTAINER_NAME}

    lxc network attach ${LXD_NETWORK} ${CONTAINER_NAME} eth0 eth0
    lxc config device set ${CONTAINER_NAME} eth0 ipv4.address ${CONTAINER_IP}
    lxc start ${CONTAINER_NAME} 

    echo ${MX_HOST}|lxc exec ${CONTAINER_NAME} tee /etc/hostname
    lxc restart ${CONTAINER_NAME}

    add_proxy_port "${CONTAINER_NAME}" "http" "${HOST_IPv4}:80" "${CONTAINER_IP}:80"
    add_proxy_port "${CONTAINER_NAME}" "https" "${HOST_IPv4}:443" "${CONTAINER_IP}:443"
    add_proxy_port "${CONTAINER_NAME}" "smtp" "${HOST_IPv4}:25" "${CONTAINER_IP}:25"
    add_proxy_port "${CONTAINER_NAME}" "esmtp" "${HOST_IPv4}:587" "${CONTAINER_IP}:587"
fi

# Generate a script to run in the container to configure OpenSMTPD

cat <<SCRIPT_EOF | lxc exec ${CONTAINER_NAME} tee build_container.sh
#!/bin/bash

while ! id ${PRIMARY_USER}; do
    echo -e "\nCreate the primary user account '${PRIMARY_USER}' (this will be ${PRIMARY_USER}@${DOMAIN})"
    adduser ${PRIMARY_USER}
done

apt-get update
apt-get install apt-utils debconf-utils

echo "opensmtpd opensmtpd/mailname string ${DOMAIN}"|debconf-set-selections
echo "opensmtpd opensmtpd/root_address string ${PRIMARY_USER}"|debconf-set-selections

apt-get install procps curl cron opensmtpd

apt-get install apache2 opensmtpd dkimproxy

# Add a delay to smtpd startup to avoid binding to an unconfigured interface
if ! grep 'ExecStartPre' /lib/systemd/system/opensmtpd.service; then
    sed -i 's/ExecStart=/ExecStartPre=\/bin\/sleep 3\nExecStart=/' /lib/systemd/system/opensmtpd.service
fi

# Ensure dkimproxy can read the private key, and disable DKIM incoming
# verification, and uncomment the DOMAIN variable.
chgrp dkimproxy /var/lib/dkimproxy/private.key
sed -E -i -e 's/#RUN_DKIMPROXY_IN=1/RUN_DKIMPROXY_IN=0/' \\
          -e 's/^#?DOMAIN=.+/DOMAIN=${DOMAIN}/' /etc/default/dkimproxy

# Generate our DKIM key for our DNS configuration
DKIM_PUB=\$(for l in \$(grep -v 'PUBLIC KEY' /var/lib/dkimproxy/public.key); do echo -n \${l}; done)
DKIM_DNS="v=DKIM1; k=rsa; p=\${DKIM_PUB}"
SPF_DNS="v=spf1 a mx ip4:${PUBLIC_IPv4} -all"
echo -e "\nThe following entry should be present in your DNS zone file: -\n"
echo -e "
 mainsel._domainkey  TXT  600  \"\${DKIM_DNS}\"
 @                   TXT  1800 \"\${SPF_DNS}\"
 _dmarc              TXT  1800 \"v=DMARC1;p=reject;rua=mailto:postmaster@${DOMAIN};ruf=mailto:postmaster@${DOMAIN};pct=100\"
"|tee DNS_${DOMAIN}.txt
echo -e "Written to file 'DNS_${DOMAIN}.txt' for reference\n"
read -p 'Press enter to continue. '

# Generate a LetsEncrypt TLS certificate that can be used both
# for Apache and OpenSMTPD.

curl -s https://get.acme.sh | bash

if ! echo \$PATH|grep acme.sh; then
    PATH=/root/.acme.sh:\${PATH}
fi

acme.sh --issue ${ACME_DOMAINS} -w /var/www/html

mkdir -p /etc/letsencrypt/acme.sh

acme.sh --install-cert ${ACME_DOMAINS} \
    --cert-file      /etc/letsencrypt/acme.sh/cert-${DOMAIN}.pem  \
    --key-file       /etc/letsencrypt/acme.sh/cert-${DOMAIN}.key  \
    --fullchain-file /etc/letsencrypt/acme.sh/fullchain-${DOMAIN}.pem \
    --reloadcmd     "service apache2 force-reload"
SCRIPT_EOF

# Execute our generated script to configure OpenSMTPD
lxc exec ${CONTAINER_NAME} chmod a+x build_container.sh
lxc exec ${CONTAINER_NAME} bash build_container.sh

# Populate the template for smtpd.conf
cat smtpd.conf.template | sed \
	-e "s/\${DOMAIN}/${DOMAIN}/g" \
	-e "s/\${MAIL_FQDN}/${MAIL_FQDN}/g" \
	|lxc exec ${CONTAINER_NAME} tee /etc/smtpd.conf
lxc exec ${CONTAINER_NAME} systemctl restart opensmtpd

# At this point, we should have a working SMTP server.

# Install and configure Dovecot IMAP server.

CONFIG_TAG='\\\$config\['   # to match '$config[' in files without crazy escapes

cat <<SCRIPT_EOF | lxc exec ${CONTAINER_NAME} tee configure_imap.sh
#!/bin/bash

echo "roundcube-core  roundcube/dbconfig-install      boolean true"|debconf-set-selections
apt-get install dovecot-imapd roundcube roundcube-sqlite3

# We use Maildir format for our mail storage.
sed -E -i 's/^mail_location[ ]?=[ ]?mbox:.+/mail_location = maildir:~\\/Maildir/' /etc/dovecot/conf.d/10-mail.conf

# Our default IMAP host will be localhost port 143
sed -E -i "s/^(${CONFIG_TAG}'default_host'] = ).*/\\1'localhost:143';/" /etc/roundcube/config.inc.php

# We don't use SMTP authentication, since we're connecting locally, so comment these out.
sed -E -i "s/^(${CONFIG_TAG}'smtp_(user|pass)'] = )(.*)/\\/\\/\\1\3/" /etc/roundcube/config.inc.php

# Our mail domain (e.g. after the @ in user@example.com) is our registered domain.
sed -E -i "s/^(${CONFIG_TAG}'mail_domain'] = ).*/\\1'${DOMAIN}';/" /etc/roundcube/defaults.inc.php

# Set the DKIM selector. This is ultimately used to identify which TXT record
# to consult when fetching our DKIM public key via DNS.
sed -E -i -e 's/^(selector ).+/\1 mainsel/' \\
          -e 's/^domain .+/domain  ${DOMAIN}/' /etc/dkimproxy/dkimproxy_out.conf

a2enmod ssl

SCRIPT_EOF

lxc exec ${CONTAINER_NAME} chmod a+x configure_imap.sh
lxc exec ${CONTAINER_NAME} bash configure_imap.sh

# Install our roundcube Apache virtual host
cat http_roundcube.conf.template | sed -e "s/\${DOMAIN}/${DOMAIN}/g" |lxc exec ${CONTAINER_NAME} tee /etc/apache2/sites-available/roundcube.conf
lxc exec ${CONTAINER_NAME} -- bash -c 'a2ensite roundcube; systemctl restart apache2'

echo "All done. Restarting the container to ensure all services come up."
lxc restart ${CONTAINER_NAME}

