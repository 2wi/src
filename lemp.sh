#!/bin/bash
#
# metadata_begin
# recipe: LEMP
# tags: centos8,alma8,alma9,rocky8,oracle8,debian10,debian11,ubuntu1804,ubuntu2004
# revision: 3
# description_ru: Linux+Nginx+MySQL+PHP
# description_en: Linux+Nginx+MySQL+PHP
# metadata_end
#

set -x

LOG_PIPE=/tmp/log.pipe.$$

mkfifo ${LOG_PIPE}
LOG_FILE=/root/lemp.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}

tee < ${LOG_PIPE} ${LOG_FILE} &

exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

killjobs() {
    test -n "$(jobs -p)" && kill $(jobs -p) || :
}
trap killjobs INT TERM EXIT

echo
echo "=== Recipe LAMP started at $(date) ==="
echo

if [ -f /etc/redhat-release ]; then
    OSNAME=centos
else
    OSNAME=debian
fi

RootMyCnf() {
    # Saving mysql password
    touch /root/.my.cnf
    chmod 600 /root/.my.cnf
    echo "[client]" > /root/.my.cnf
    echo "password=${1}" >> /root/.my.cnf

}

if [ "${OSNAME}" = "debian" ]; then
    export DEBIAN_FRONTEND="noninteractive"
    # Wait firstrun script
    while ps uxaww | grep  -v grep | grep -Eq 'apt-get|dpkg' ; do echo "waiting..." ; sleep 3 ; done
    apt-get update --allow-releaseinfo-change || :
    apt-get update
    which which 2>/dev/null || apt-get -y install which
    which lsb-release 2>/dev/null || apt-get -y install lsb-release
    which logger 2>/dev/null || apt-get -y install bsdutils
    which curl 2>/dev/null || apt-get -y install curl
    pkglist="vim nginx"
    DEB_VERSION=$(lsb_release -r -s)
    DEB_FAMILY=$(lsb_release -s -i)
    if [ "${DEB_FAMILY}" = "Debian" ] && [ ${DEB_VERSION} -ge 10 ]; then
        MYSQL_VERSION="mariadb-server"
    else
        MYSQL_VERSION="mysql-server"
    fi
    if ! dpkg -s ${MYSQL_VERSION} >/dev/null 2>/dev/null; then
        install_mysql=yes
        pkglist="${pkglist} ${MYSQL_VERSION}"
    fi
    pkglist="${pkglist} php-mbstring php-zip php-gd php-xml php-pear php-cgi php-mysqli php-fpm"
    unpack_phpmyadmin=yes

    _tmppass="($PASS)"
    if [ -n "${_tmppass}" ] && [ "${_tmppass}" != "()" ]; then
        mysqlpass="${_tmppass}"
    else
        apt-get -y install pwgen
        mysqlpass=$(pwgen -s 10 1)
    fi

    if [ -n "${install_mysql}" ]; then
        # Setting mysql root password
        echo "${MYSQL_VERSION} ${MYSQL_VERSION}/root_password password ${mysqlpass}" | debconf-set-selections
        echo "${MYSQL_VERSION} ${MYSQL_VERSION}/root_password_again password ${mysqlpass}" | debconf-set-selections
    fi

    # Installing packages
    apt-get -y install ${pkglist}

    if [ -n "${install_mysql}" ] && [ ! -e /root/.my.cnf ]; then
        RootMyCnf ${mysqlpass}
    fi

    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        apt-get -f install
        systemctl restart nginx
    fi

     curl -s --connect-timeout 30 --retry 10 --retry-delay 5 -k -L "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz" > pma.tar.gz
    mkdir /var/www/html/phpmyadmin
    tar xzf pma.tar.gz --strip-components=1 -C /var/www/html/phpmyadmin
    rm pma.tar.gz
    cp /var/www/html/phpmyadmin/config{.sample,}.inc.php
    chmod 660 /var/www/html/phpmyadmin/config.inc.php
    sed -i "/blowfish_secret/s/''/'$(pwgen -s 32 1)'/" /var/www/html/phpmyadmin/config.inc.php
    chown -R www-data:www-data /var/www/html/phpmyadmin
    test -f /etc/nginx/conf.d/default.conf && rm -f /etc/nginx/conf.d/default.conf
    # Узнаём версию php
    fpmver=$(php -v | head -1 | cut -c5-7)
    cat > /etc/nginx/conf.d/phpmyadmin.conf << EOF
server {
  listen 80;
  listen [::]:80;
  server_name _;
  root /usr/share/nginx/html/;
  index index.php index.html index.htm index.nginx-debian.html;

  location / {
    try_files \$uri \$uri/ =404;
  }

  location ~ \.php$ {
    fastcgi_pass unix:/run/php/php$fpmver-fpm.sock;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
    include snippets/fastcgi-php.conf;
  }

  location /phpmyadmin {
    root /var/www/html/;
    index index.php index.html index.htm;
    location ~* ^/phpmyadmin/(.+\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
            root /var/www/html/;
    }
    location ~  ^/phpmyadmin/(.+\.php)$ {
            fastcgi_pass unix:/run/php/php$fpmver-fpm.sock;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            include fastcgi_params;
            include snippets/fastcgi-php.conf;
    }
  }

  location ~ /\.ht {
      access_log off;
      log_not_found off;
      deny all;
  }
}
EOF
    systemctl restart nginx
else
    OSREL=$(rpm -qf --qf '%{version}' /etc/redhat-release | cut -d . -f 1)

    # Setting proxy
    if [ ! "($HTTPPROXYv4)" = "()" ]; then
        # Стрипаем пробелы, если они есть
        PR="($HTTPPROXYv4)"
        PR=$(echo ${PR} | sed "s/''//g" | sed 's/""//g')
        if [ -n "${PR}" ]; then
            echo "proxy=${PR}" >> /etc/yum.conf
            #export http_proxy="${PR}"
            #export HTTP_PROXY="${PR}"
        fi
    fi


    Service() {
        # $1 - name
        # $2 - command

        if [ -f /usr/bin/systemctl ]; then
            systemctl ${2} ${1}.service
        else
            if [ "${2}" = "enable" ]; then
                chkconfig ${1} on
            else
                service ${1} ${2}
            fi
        fi
    }

    yum -y install epel-release || yum -y install oracle-epel-release-el8

    # nginx repo
    cat > /etc/yum.repos.d/nginx.repo << EOF
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/centos/${OSREL}/\$basearch/
gpgcheck=0
enabled=1
EOF
    
    pkglist="vim nginx php php-pdo php-xml php-pecl-zip php-json php-common php-fpm php-mbstring php-cli php-mysqlnd php-json php-mbstring wget unzip tar pwgen mariadb-server"
    mysqlname=mariadb
    yum -y install ${pkglist} || yum -y install ${pkglist} || yum -y install ${pkglist}

    mkdir /usr/share/phpmyadmin
    curl -s --connect-timeout 30 --retry 10 --retry-delay 5 -k -L "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz" | tar xz --strip-components=1 -C /usr/share/phpmyadmin
    mv /usr/share/phpmyadmin/config{.sample,}.inc.php
    sed -i "/blowfish_secret/s/''/'$(pwgen -s 32 1)'/" /usr/share/phpmyadmin/config.inc.php
    mkdir /usr/share/phpmyadmin/tmp
    chown -R apache:apache /usr/share/phpmyadmin
    chmod 777 /usr/share/phpmyadmin/tmp
    firewall-cmd --permanent --add-service=http
    firewall-cmd --reload

    test -f /etc/nginx/conf.d/default.conf && rm -f /etc/nginx/conf.d/default.conf
    sed -i '/server {/,$c}' /etc/nginx/nginx.conf
    # Всё работает под юзером apache (строка 209), на него садим nginx
    sed -i -r '/^\s*user\s/ s/nginx/apache/' /etc/nginx/nginx.conf
    cat > /etc/nginx/conf.d/phpmyadmin.conf << EOF
server {
  listen 80;
  listen [::]:80;
  server_name _;
  root /usr/share/nginx/html/;
  index index.php index.html index.htm index.nginx-debian.html;

  location / {
    try_files \$uri \$uri/ =404;
  }

  location ~ \.php$ {
    fastcgi_pass unix:/run/php-fpm/www.sock;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
  }

  location /phpmyadmin {
    root /usr/share/;
    index index.php index.html index.htm;
    location ~* ^/phpmyadmin/(.+\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
            root /usr/share/;
    }
    location ~  ^/phpmyadmin/(.+\.php)$ {
            fastcgi_pass unix:/run/php-fpm/www.sock;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            include fastcgi_params;
    }
  }

  location ~ /\.ht {
      access_log off;
      log_not_found off;
      deny all;
  }
}
EOF
    Service nginx enable
    Service nginx start
    Service ${mysqlname} enable
    Service php-fpm enable
    Service php-fpm start

    if [ -z "$(ls /var/lib/mysql/)" ]; then
        install_mysql=yes
    fi
    Service ${mysqlname} start

    if [ -n "${install_mysql}" ]; then
        # Setting mysql password
        _tmppass="($PASS)"
        if [ -n "${_tmppass}" ] && [ "${_tmppass}" != "()" ]; then
            mysqlpass="${_tmppass}"
        else
            rpm -q pwgen || yum -y install pwgen
            mysqlpass=$(pwgen -s 10 1)
        fi
        /usr/bin/mysqladmin -u root password ${mysqlpass}
        RootMyCnf ${mysqlpass}
        echo "DELETE FROM user WHERE Password='';" | mysql --defaults-file=/root/.my.cnf -N mysql
    fi

    # Removing proxy
    sed -r -i "/proxy=/d" /etc/yum.conf
fi
