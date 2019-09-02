# lxd-email-server
Create an LXD container for SMTP, IMAP, and WebMail using OpenSMTPD, Dovecot, and Roundcube, with DKIMProxy for signing outgoing messages and acme.sh for creating and maintaining a LetsEncrypt certificate for both the webmail server and the SMTP server.

This script is intended for technical people who want to manage their own email server. It requires a VPS with a public IPv4 address, and of course a registered domain. The domain's DNS entries will need to be accessible, and it's highly recommended that reverse DNS is configured for the IP address of the VPS.

The build_server.sh script will check your DNS configuration, then create a container and configure its network to NAT ports 25, 587, 80, and 443 to the container.

The container itself will be installed with OpenSMTPD, DKIMProxy, Dovecot, acme.sh, Apache, and Roundcube, and these will be configured automatically to the point that email can be sent and received, with incoming mail accessible via HTTPS using Roundcube.

The script will generate the required DNS entries, such as the SPF and DKIM records, but you will need to manually enter these into your DNS zone file, typically managed in your domain registrar account.

## Requirements
You will need a VPS with a public IP address, installed with Debian Stretch or Buster. To get LXD installed on a fresh VPS, run the following as root: -
```bash
apt-get update
apt-get dist-upgrade
apt-get install sudo
```
Then make sure you're in the sudo group (e.g. `root@vps:~# adduser kevin sudo`) and run the following as your normal user: -
```bash
sudo apt-get install snapd
sudo snap install lxd
```
You should now make sure that you have DNS A records for your domain. The hosts `www`, `webmail`, and `mail` should all point to your IP address. Your reverse DNS should be configured such that your IP address resolves back to your mail host (e.g. 1.2.3.4 resolves to mail.example.com).
## Installation
Clone this repository, then `cd lxd-email-server`, and run `./build_server.sh`. The process should take 10 minutes.

During the installation, the script will output the DNS records that need to be added to your domain's zone. These will also be written to the container's filesystem for reference, under the name `DNS_example.com.txt` (whatever your domain is). You can use these values as reference when configuring your DNS from your domain registrar's web interface.

If you need to get a shell on your container (called `mymail` in the default config file), then use: -
```bash
lxc exec mymail bash
```

## Still to be done
There is no external IMAP port open and I haven't configured SMTP username/password authentication to allow external access to sending and receiving emails (e.g. from your phone). If you need these you'll currently need to configure this yourself.

Any pull requests for generally useful additional features are welcome.

## Altnernative
The project mail-in-a-box https://github.com/mail-in-a-box/mailinabox is a turnkey solution that's mature and appears to be well documented for non-technical users. My lxd-email-server project, on the other hand, is intended as more of a shortcut or reference for people who could configure this themselves, but choose not to for whatever reason.

## Acknowledgements
All credits go to the people who contribute to the projects mentioned here - OpenSMTPD, Dovecot, Roundcube, DKIMProxy, acme.sh, and of course Apache, GNU, Linux, and the Debian maintainers, whose well considered efforts mean that I can script an automated installation and configuration in a small bash script. Thanks!
