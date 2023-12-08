#!/bin/bash
#
# metadata_begin
# recipe: LAMP
# tags: centos,alma8,alma9,rocky8,oracle8,debian,ubuntu1604,ubuntu1804,ubuntu2004
# revision: 14
# description_ru: LAMP + Nginx
# description_en: LAMP + Nginx
# metadata_end
#

set -x

LOG_PIPE=/tmp/log.pipe.$$

mkfifo ${LOG_PIPE}
LOG_FILE=/root/lamp.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}

tee < ${LOG_PIPE} ${LOG_FILE} &

exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

killjobs() {
	# shellcheck disable=SC2046,SC2015
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
	# shellcheck disable=SC2009
	while ps uxaww | grep  -v grep | grep -Eq 'apt-get|dpkg' ; do echo "waiting..." ; sleep 3 ; done
	apt-get update --allow-releaseinfo-change || :
    apt-get update
    which which 2>/dev/null || apt-get -y install which
    which lsb-release 2>/dev/null || apt-get -y install lsb-release
    which logger 2>/dev/null || apt-get -y install bsdutils
    which curl 2>/dev/null || apt-get -y install curl
    pkglist="vim apache2 nginx"
    DEB_VERSION=$(lsb_release -r -s)
	DEB_FAMILY=$(lsb_release -s -i)
	# shellcheck disable=SC2086
	if [ "${DEB_FAMILY}" = "Debian" ] && [ ${DEB_VERSION} -ge 10 ]; then
        MYSQL_VERSION="mariadb-server"
    else
        MYSQL_VERSION="mysql-server"
    fi
    if ! dpkg -s ${MYSQL_VERSION} >/dev/null 2>/dev/null; then
        install_mysql=yes
        pkglist="${pkglist} ${MYSQL_VERSION}"
    fi
    if [ "${DEB_VERSION}" = "10" ]; then
        pkglist="${pkglist} php-mbstring php-zip php-gd php-xml php-pear php-cgi php-mysqli"
        unpack_phpmyadmin=yes
    else
        if ! dpkg -s phpmyadmin >/dev/null 2>/dev/null; then
            install_phpmyadmin=yes
            pkglist="${pkglist} phpmyadmin"
            echo "phpmyadmin      phpmyadmin/reconfigure-webserver        multiselect     apache2" | debconf-set-selections
        fi
    fi
    if [ "$(lsb_release -s -c)" = "trusty" ] || [ "$(lsb_release -s -c)" = "wheezy" ] ; then
        pkglist="${pkglist} libapache2-mod-php5 php5-cli"
    else
        pkglist="${pkglist} libapache2-mod-php php-cli"
    fi

    if [ "$(lsb_release -s -c)" = "stretch" ]; then
        curl -o- http://nginx.org/keys/nginx_signing.key | apt-key add -
        echo "deb http://nginx.org/packages/debian/ $(lsb_release -s -c) nginx" > /etc/apt/sources.list.d/nginx.list
        apt-get update
    fi


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

    if [ -n "${install_phpmyadmin}" ]; then
        echo "phpmyadmin phpmyadmin/mysql/admin-pass password ${mysqlpass}" | debconf-set-selections
    fi

    # Installing packages
	# shellcheck disable=SC2086
    apt-get -y install ${pkglist}

    if [ -n "${install_mysql}" ] && [ ! -e /root/.my.cnf ]; then
        RootMyCnf "${mysqlpass}"
    fi

    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        apt-get -f install
        systemctl restart nginx
        systemctl restart apache2
    fi

    if [ -n "${unpack_phpmyadmin}" ]; then
         curl -s --connect-timeout 30 --retry 10 --retry-delay 5 -k -L "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz" > pma.tar.gz
        mkdir /var/www/html/phpmyadmin
        tar xzf pma.tar.gz --strip-components=1 -C /var/www/html/phpmyadmin
        rm pma.tar.gz
        cp /var/www/html/phpmyadmin/config{.sample,}.inc.php
        chmod 660 /var/www/html/phpmyadmin/config.inc.php
        sed -i "/blowfish_secret/s/''/'$(pwgen -s 32 1)'/" /var/www/html/phpmyadmin/config.inc.php
        chown -R www-data:www-data /var/www/html/phpmyadmin
        test -f /etc/nginx/conf.d/default.conf && rm -f /etc/nginx/conf.d/default.conf
        systemctl restart nginx
        systemctl restart apache2
    fi
else
	# shellcheck disable=SC2046
    OSREL=$(rpm -qf --qf '%{version}' /etc/redhat-release | cut -d . -f 1)

    # Setting proxy
	# shellcheck disable=SC2154
    if [ ! "($HTTPPROXYv4)" = "()" ]; then
        # Стрипаем пробелы, если они есть
        PR="($HTTPPROXYv4)"
        PR=$(echo "${PR}" | sed "s/''//g" | sed 's/""//g')
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
            systemctl "${2}" "${1}.service"
        else
            if [ "${2}" = "enable" ]; then
                chkconfig "${1}" on
            else
                service "${1}" "${2}"
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
    
    pkglist="vim nginx httpd php php-pdo php-xml php-pecl-zip php-json php-common php-fpm php-mbstring php-cli php-mysqlnd php-json php-mbstring wget unzip tar pwgen"
    if [ "${OSREL}" -ge 7 ]; then
        pkglist="${pkglist} mariadb-server"
        mysqlname=mariadb
    else
        pkglist="${pkglist} mysql-server"
        mysqlname=mysqld
    fi
    if [ "${OSREL}" != "8" ] && [ "${OSREL}" != "9" ]; then
        pkglist="${pkglist} phpmyadmin"
    fi
	# shellcheck disable=SC2086
    yum -y install ${pkglist} || yum -y install ${pkglist} || yum -y install ${pkglist}

    if [ -f /etc/httpd/conf.d/phpMyAdmin.conf ]; then
        cat > /tmp/sed.$$ << EOF
/<Directory \/usr\/share\/phpMyAdmin\/>/,/<\/Directory>/ {
    /<RequireAny>/,/<\/RequireAny>/d;
    /<IfModule !mod_authz_core.c>/,/<\/IfModule>/s/Deny from All/Allow from All/g;
    /<IfModule mod_authz_core.c>/a\\\tRequire all granted 
};
/<Directory \/usr\/share\/phpMyAdmin\/setup\/>/,/<\/Directory>/ {
    /<IfModule mod_authz_core.c>/a\\\tRequire all denied
    /<RequireAny>/,/<\/RequireAny>/d;
    /<IfModule !mod_authz_core.c>/,/<\/IfModule>/{ /Allow from/d}
}
EOF
        sed -i -r -f /tmp/sed.$$ /etc/httpd/conf.d/phpMyAdmin.conf
    else
        mkdir /usr/share/phpmyadmin
        curl -s --connect-timeout 30 --retry 10 --retry-delay 5 -k -L "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz" | tar xz --strip-components=1 -C /usr/share/phpmyadmin
        mv /usr/share/phpmyadmin/config{.sample,}.inc.php
        sed -i "/blowfish_secret/s/''/'$(pwgen -s 32 1)'/" /usr/share/phpmyadmin/config.inc.php
        mkdir /usr/share/phpmyadmin/tmp
        chown -R apache:apache /usr/share/phpmyadmin
        chmod 777 /usr/share/phpmyadmin/tmp
        cat << EOF > /etc/httpd/conf.d/phpmyadmin.conf
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin/>
   AddDefaultCharset UTF-8

   <IfModule mod_authz_core.c>
     # Apache 2.4
     <RequireAny>
      Require all granted
     </RequireAny>
   </IfModule>
   <IfModule !mod_authz_core.c>
     # Apache 2.2
     Order Deny,Allow
     Deny from All
     Allow from 127.0.0.1
     Allow from ::1
   </IfModule>
</Directory>

<Directory /usr/share/phpmyadmin/setup/>
   <IfModule mod_authz_core.c>
     # Apache 2.4
     <RequireAny>
       Require all granted
     </RequireAny>
   </IfModule>
   <IfModule !mod_authz_core.c>
     # Apache 2.2
     Order Deny,Allow
     Deny from All
     Allow from 127.0.0.1
     Allow from ::1
   </IfModule>
</Directory>
EOF
        firewall-cmd --permanent --add-service=http
        firewall-cmd --reload
    fi

    test -f /etc/nginx/conf.d/default.conf && rm -f /etc/nginx/conf.d/default.conf

    Service httpd enable
    Service httpd start
    Service nginx enable
    Service nginx start
    Service ${mysqlname} enable

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
        /usr/bin/mysqladmin -u root password "${mysqlpass}"
        RootMyCnf "${mysqlpass}"
        echo "DELETE FROM user WHERE Password='';" | mysql --defaults-file=/root/.my.cnf -N mysql
    fi

    # Removing proxy
    sed -r -i "/proxy=/d" /etc/yum.conf
fi
