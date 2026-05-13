#!/bin/bash
# AMIMOTO AMI AL2023 - Initial WordPress Setup
# This script runs on first boot to configure the instance and install WordPress
set -e

export PATH=/sbin:/bin:/usr/bin:/usr/local/bin:$PATH

# IMDSv2 token
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
IMDS_HEADER="X-aws-ec2-metadata-token: ${IMDS_TOKEN}"

INSTANCETYPE=$(curl -s -H "${IMDS_HEADER}" http://169.254.169.254/latest/meta-data/instance-type)
INSTANCEID=$(curl -s -H "${IMDS_HEADER}" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "${IMDS_HEADER}" http://169.254.169.254/latest/meta-data/placement/availability-zone)
PUBLIC_IPV4=$(curl -s -H "${IMDS_HEADER}" http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")
LOCAL_IPV4=$(curl -s -H "${IMDS_HEADER}" http://169.254.169.254/latest/meta-data/local-ipv4)
REGION=$(echo ${AZ} | sed -e 's/[a-z]$//')

SERVERNAME=${INSTANCEID}
ANSIBLE_PATH="/opt/local/ansible"

## cleanup and initialize
/usr/bin/crontab -r 2>/dev/null || true

/bin/rm -f  /root/.bash_history
/bin/rm -f  /home/ec2-user/.bash_history
/bin/rm -rf /var/www/vhosts/i-*
/bin/rm -rf /var/log/nginx/*
/bin/rm -rf /var/cache/nginx/*
/bin/rm -rf /var/log/php-fpm/*

## ensure directories
[ ! -d /var/www/vhosts/${SERVERNAME} ] && \
  /bin/mkdir -p /var/www/vhosts/${SERVERNAME}
/bin/chown -R amimoto-user:www /var/www/vhosts/${SERVERNAME}
[ ! -d /etc/nginx/vhosts.d ] && \
  /bin/mkdir -p /etc/nginx/vhosts.d

# placeholder page
index_html='<html>
<head><title>Setting up your WordPress now.</title></head>
<body><p>Setting up your WordPress now.</p><p>After a while please reload your web browser.</p></body>
</html>'
echo "${index_html}" > /var/www/vhosts/${SERVERNAME}/index.html
echo "${index_html}" > /var/www/html/index.html


## update Ansible bundle from S3 or GitHub
ANSIBLE_REPO="https://github.com/amimoto-ami/amimoto-ami2023.git"

if [ -d "${ANSIBLE_PATH}/.git" ]; then
  /usr/bin/git -C ${ANSIBLE_PATH} pull origin main || true
else
  /usr/bin/dnf -y install ansible-core git || /usr/bin/dnf -y install ansible git
  /usr/bin/git clone ${ANSIBLE_REPO} ${ANSIBLE_PATH} || true
fi

[ ! -d ${ANSIBLE_PATH}/ansible/inventory ] && \
  mkdir -p ${ANSIBLE_PATH}/ansible/inventory
echo -e "[amimoto]\nlocalhost ansible_connection=local" > ${ANSIBLE_PATH}/ansible/inventory/hosts.ini


## create provision script (runs on reboot)
cat << 'EOS' > /opt/local/provision
#!/bin/bash
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
IMDS_HEADER="X-aws-ec2-metadata-token: ${IMDS_TOKEN}"
AZ=$(curl -s -H "${IMDS_HEADER}" http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=$(echo ${AZ} | sed -e 's/[a-z]$//')
ANSIBLE_PATH="/opt/local/ansible"

if [ -d "${ANSIBLE_PATH}/.git" ]; then
  /usr/bin/git -C ${ANSIBLE_PATH} pull origin main || true
fi
/usr/bin/ansible-playbook \
  -i ${ANSIBLE_PATH}/ansible/inventory/hosts.ini \
  ${ANSIBLE_PATH}/ansible/site.yml \
  -e "amimoto_ec2_region=${REGION}" 2>&1 | tee -a /var/log/amimoto/provision.log
EOS
chmod +x /opt/local/provision

/usr/bin/crontab -r 2>/dev/null || true
echo '@reboot /bin/bash /opt/local/provision > /dev/null 2>&1' | crontab


## provision (run Ansible for instance tuning)
mkdir -p /var/log/amimoto
/usr/bin/ansible-playbook \
  -i ${ANSIBLE_PATH}/ansible/inventory/hosts.ini \
  ${ANSIBLE_PATH}/ansible/site.yml \
  -e "amimoto_ec2_region=${REGION}" 2>&1 | tee -a /var/log/amimoto/provision.log


## install WordPress
WP_CLI="/usr/local/bin/wp"

## create database and user (root via unix_socket)
DB_NAME="wp_$(echo ${SERVERNAME} | tr '-' '_' | cut -c1-16)"
DB_USER="wp_$(echo ${SERVERNAME} | tr '-' '_' | cut -c1-13)"
DB_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

mariadb -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
mariadb -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
mariadb -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true

cd /var/www/vhosts/${SERVERNAME}
if ! ${WP_CLI} --allow-root core is-installed --path=/var/www/vhosts/${SERVERNAME} 2>/dev/null; then
  # download WordPress
  sudo -u amimoto-user ${WP_CLI} core download --locale=ja --path=/var/www/vhosts/${SERVERNAME}

  # generate wp-config.php
  sudo -u amimoto-user ${WP_CLI} config create \
    --dbname="${DB_NAME}" \
    --dbuser="${DB_USER}" \
    --dbpass="${DB_PASS}" \
    --dbhost="localhost" \
    --path=/var/www/vhosts/${SERVERNAME}

  # determine URL
  if [ -n "${PUBLIC_IPV4}" ] && ! echo "${PUBLIC_IPV4}" | grep -q "Not Found"; then
    WP_URL=${PUBLIC_IPV4}
  else
    WP_URL=${LOCAL_IPV4}
  fi

  # install WordPress
  ${WP_CLI} --allow-root core install \
    --url="http://${WP_URL}" \
    --title="AMIMOTO WordPress" \
    --admin_user="admin" \
    --admin_email="admin@example.com" \
    --admin_password="${SERVERNAME}" \
    --skip-email \
    --path=/var/www/vhosts/${SERVERNAME}

  # fix ownership
  /bin/chown -R amimoto-user:www /var/www/vhosts/${SERVERNAME}
fi

# cleanup placeholder
[ -f /var/www/html/index.html ] && \
  /bin/rm -f /var/www/html/index.html
[ -f /var/www/vhosts/${SERVERNAME}/index.html ] && \
  /bin/rm -f /var/www/vhosts/${SERVERNAME}/index.html

# fix permissions
/bin/chown -R amimoto-user:www /var/log/nginx
/bin/chown -R amimoto-user:www /var/log/php-fpm
/bin/chown -R amimoto-user:www /var/www/vhosts/${SERVERNAME}

echo "AMIMOTO WordPress setup completed at $(date)" | tee -a /var/log/amimoto/wp-setup.log
