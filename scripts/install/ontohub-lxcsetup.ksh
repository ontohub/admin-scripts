#!/bin/ksh93

# see https://github.com/ontohub/ontohub/wiki/Productive-Deployment
# https://github.com/ontohub/ontohub/wiki/Our-productive-configuration
# NOTE: passenger 4.0.53 and .40 (other versions not tested) seem to not work
#       in environments where real concurrency occures/LXC zones 

SDIR=$( cd ${ dirname $0; }; printf "$PWD" )
MAC_PREFIX=0:80:41
ZNMASK='/24'
ZBASE=/tmp

RBENV_ROOT='/local/usr/ruby'
RUBY_VERS='2.1.1'	# fallback for ~ontohub/ontohub/.ruby-version
SOLR_VERS='4.7.2'

. ${SDIR}/lxc-install.kshlib || exit 1

if [[ -z ${BRANCH} ]]; then
	if [[ $ZNAME == 'ta' || $ZNAME == 'ontohub' || $ZNAME == 'www' ]]; then
		BRANCH='master'
	elif [[ ${ZNAME} == 'tb' ]]; then
		BRANCH='staging'
	else
		BRANCH='develop'
	fi
fi
Log.info "Using branch '${BRANCH}' as zone's default branch ..."

USEFIXTMP=1

WEBSERVD_UID=80 WEBSERVD_GID=80 PSQL_UID=90 PSQL_GID=90	# system predefined

ZGROUP[redis]=( name='redis' gid=117 )
ZGROUP[ruby]=( name='ruby' gid=118 )
ZUSER[webadm]=(
	login=webadm uid=114 gid=10 gcos='Webmaster' )
ZUSER[redis]=(
	login=redis uid=117 gid=117 gcos='Redis DB daemon' shell=/bin/false )
ZUSER[ruby]=(
	login=ruby uid=118 gid=118 gcos='Ruby Admin' shell=/bin/bash )
ZUSER[ontohub]=(
	login=ontohub uid=119 gid=${WEBSERVD_GID} gcos='Ontohub Admin' shell=/bin/bash )
ZUSER[git]=(
	login=git uid=120 gid=${WEBSERVD_GID} gcos='Git Repository' shell=/bin/bash )

# ACHTUNG! Ubuntu's ksh93 version is buggy! Für oktale Zahlen reicht '0' als
# als prefix nicht aus. Prefix '8#' ist erforderlich!

# Von der GZ an die NGZ zu vererbende datasets:
DATADIR[pool1]=(	# HDDs
	pool=${GZPOOL}/${ZNAME}/pool1 z_pool=pool1
	zopts='compression=on atime=off setuid=off' )
DATADIR[pool2]=(	# SSDs
	pool=${GZPOOL2}/${ZNAME}/pool2 z_pool=pool2
	zopts='compression=on atime=off setuid=off' )

# NGZ "interne" datasets 
DATADIR[web]=(
	z_pool=pool1/data/web z_dir=/data/web
	mode=8#0755 )
DATADIR[sites]=(
	z_pool=pool1/data/web/sites
	mode=8#0755 uid=${ZUSER[ontohub].uid} gid=${ZUSER[ontohub].gid} )
DATADIR[git]=(
	z_pool=pool1/data/git z_dir=/data/git
	mode=8#0775 uid=${ZUSER[ontohub].uid} gid=${WEBSERVD_GID} )
# hardcoded into ontohub
for X in repositories git_daemon commits .ssh ; do
	DATADIR[git.${X#.}]=( z_dir=/data/git/$X
		mode=8#0775 uid=${ZUSER[git].uid} gid=${WEBSERVD_GID} )
done
DATADIR[redis]=(
	z_pool=pool2/data/redis z_dir=/data/redis
	mode=8#0755 uid=${ZUSER[redis].uid} gid=${ZUSER[redis].gid} )
DATADIR[psql]=(
	z_pool=pool2/data/psql z_dir=/data/psql
	mode=8#0755 uid=${PSQL_UID} gid=${PSQL_GID} )

checkDatadirsPre
checkIP
checkNIC
checkZonePathes
createTempdir

addPkg install	sudo					# Till wills haben
addPkg install	apache2 apache2-utils	# web frontend
addPkg install	postgresql				# DB
addPkg install	ca-certificates			# let git work correctly
addPkg install	git						# ontology repo management
addPkg install	fonts-liberation		# includes best non-prop. font ever seen
# hours of work: ruby does not say, that it needs readline, but actually
# compiling without it will give a lot of headaches ('gem install rb-readline'
# is NOT a workaround).
addPkg install	libreadline6
# when proper packages for the ruby based stuff are availble, the following
# pkgs are probably not needed anymore (all required for ruby build and
# building passenger-apache2-module)
addPkg install	apache2-dev libapr1-dev libaprutil1-dev libcurl4-openssl-dev \
	libxml2-dev libxslt1-dev pkg-config libreadline-dev
addPkg install	curl gcc g++ cmake	# only rugged needs cmake (+20 M)
if [[ ${BRANCH} != 'master' && ${BRANCH} != 'staging' ]]; then
	# holy cow - capybara-webkit for ontohub testing (+230M => 1436M)
	#            if you wanna waste your time, try that with qt5
	addPkg install	libqt4-dev libqtwebkit-dev
fi

createZoneConfig
installZone || exit $?
customizeZone || exit $?

# customizations, which do not require a running/fully plumbed zone
sed -e '/^export APACHE_RUN_USER=/ s,=.*,=webservd,' \
	-e '/^export APACHE_RUN_GROUP=/ s,=.*,=webservd,' \
	-i ${ZROOT}/etc/apache2/envvars

bootZone || exit $?
checkDatadirsPost


# To avoid a chroot marathon we simply xfer the following functions as script
# as well as supporting scripts into the zone and run it there.
URL='https://raw.githubusercontent.com/ontohub/admin-scripts/master/scripts/install/'
for X in passenger.patch oh-update.sh hashCerts ; do
	if [[ ! -f ${SDIR}/$X && $X != 'passenger.patch' ]]; then
		curl -O ~admin/etc/$X ${URL}$X
		read -n 12 X <~admin/etc/$X
		[[ $X == '#!/bin/ksh93' ]] || rm -f ~admin/etc/$X
	fi
	if [[ ! -f ~admin/etc/$X ]]; then
		[[ $X == 'passenger.patch' ]] && continue	# not in repo
		print "echo Fetch $0 from '${URL}/$X' and run it." \
			>${ZROOT}/local/home/admin/etc/$X
	else
		cp ${SDIR}/$X ${ZROOT}/local/home/admin/etc/$X
		[[ $X == 'oh-update.sh' ]] && \
			sed -e "/^CFG\[datadir\]=/ s,=.*,='${DATADIR[git].z_dir}'," \
				-i ${ZROOT}/local/home/admin/etc/$X
	fi
	chmod 0755 ${ZROOT}/local/home/admin/etc/$X
done


function postRuby {
	###########################################################################
	# TBD: Usually all the ruby [related] stuff/tweaks are not acceptable in a 
	# real production env. Proper packages should be used instead!
	# Anyway, russian roulette starts:
	###########################################################################
	Log.info "$0 setup ..."
	Log.warn "$0 TBD: Use real packages!"

	typeset X RB_PROFILE="${RBENV_ROOT}/.profile" \
	postInit || return $?
	
	X="[[ -r ${RB_PROFILE} ]] && . ${RB_PROFILE}" 
	print "$X" >>~ruby/.profile
	# calls gem s well
	print "$X" >>~ontohub/.profile
	
	# rbenv stuff
	[[ ! -d ${RBENV_ROOT%/*} ]] && mkdir -p ${RBENV_ROOT%/*}
	git clone git://github.com/sstephenson/rbenv.git ${RBENV_ROOT}
	git clone git://github.com/tpope/rbenv-aliases.git \
		${RBENV_ROOT}/plugins/rbenv-aliases
	git clone git://github.com/sstephenson/ruby-build.git \
		${RBENV_ROOT}/plugins/ruby-build
	
	print 'export RBENV_ROOT="'"${RBENV_ROOT}"'"
export PATH="${RBENV_ROOT}/bin:${PATH}"
eval "$(rbenv init -)"' >${RB_PROFILE}
	
	chown -R ruby:staff ${RBENV_ROOT}
	/bin/su - ruby -c "MAKE_OPTS='-j ${JOBS}' \
		rbenv install ${RUBY_VERS} && rbenv global ${RUBY_VERS} && rbenv rehash"
	
	# ontohub environment management wrt. dependencies (gem builder)
	/bin/su - ruby -c "gem install gem-patch bundler"

	# DO NOT use nokogiri's unmaintained bundled libxml/libxslt but the ones
	#	from the system. Unfortunately ontohub uses bundler which doesn't
	#	care at all about installed system gems. So installing it here is
	#	fruitless as long as such broken tools are used and ontohub is the only
	#	consumer of it ...
	#/bin/su - ruby -c "MAKE_OPTS='-j ${JOBS}' \
	#	gem install nokogiri -- --use-system-libraries"

	# And the Passenger (Rails (Rack)) module for Apache
	# NOTE: needs a running zone (flawed comp env checks)!
	X='cd /tmp\ngem fetch passenger\nX=${ ls -1 passenger-*.gem ; }\n'
	X+='[[ -z $X ]] && exit 1\n'
	# Keep just in case we need it again
#	[[ -f ~admin/etc/passenger.patch ]] && \
#		X+='gem patch $X ~admin/etc/passenger.patch'
	X+="MAKE_OPTS='-j ${JOBS}' gem install passenger && "
	X+='passenger-install-apache2-module -a --languages=ruby'
	print "$X" >/tmp/pi.$$
	/bin/su - ruby -c "ksh93 /tmp/pi.$$"
	Log.info 'Passenger done.'
	# TBD: check the alternative:
	#print "deb https://oss-binaries.phusionpassenger.com/apt/passenger" \
	#	"${LNX_CODENAME} main" >/etc/apt/sources.list.d/passenger.list
	#apt-get update && apt-get install libapache2-mod-passenger

	mkdir -p ${RB_ETC}
	X=${ find ${RBENV_ROOT}/versions/${RUBY_VERS}/lib/ruby/gems \
			-name mod_passenger.so 2>/dev/null ; }
	[[ -z $X ]] && Log.warn "$0 - mod_passenger.so not found!" || \
		cat>${RB_ETC}/passenger.conf<<EOF
<IfModule !passenger_module>
	LoadModule	passenger_module	$X
</IfModule>
PassengerEnabled Off
#PassengerLogLevel 3
# passenger-config --ruby-command |grep Apache
PassengerDefaultRuby ${RBENV_ROOT}/versions/${RUBY_VERS}/bin/ruby
# passenger-config --root
PassengerRoot ${X%/buildout*}
PassengerMaxPoolSize 10
# NOTE: Passenger User switching is dumb! When its parent (httpd) is running
# as non-root user, passenger processes will run with the same euid/egid as
# its parent. If the parent runs with euid==root, it is impossible to instruct
# the passenger to run completely unprivileged (at least it is not documented and
# testing different combinations of related options were unsuccessful). So 
# actually the best thing to do is to run the httpd as non-root service
# with net_privaddr privileges or net_bind_service capabilities. On Linux this
# is only possible using systemd. Unfortunately even the latest Ubuntu (utopic)
# has no systemd support - it always coredumps and thus "booting" a zone becomes
# impossible. That's why we need to take the 'living in the previous century'
# approach =8-((( : start httpd as root, run it as User webservd and run 
# passenger as root and let it spawn sub processes as webservd as well.
# 
PassengerUserSwitching Off
PassengerUser webservd
PassengerDefaultUser webservd
PassengerAnalyticsLogUser webservd
EOF
	chown -R ruby:staff ${RB_ETC}

	# To check success once apache is running (the latter is brain damaged):
	# passenger-status ; passenger-memory-stats
	Log.info "Ruby setup done."
}

function postSolr {
	postInit || return $?
	(( HAS_SOLR )) || return 0

	Log.info "$0 setup ..."
	typeset X SOLRBASE='http://apache.openmirror.de/lucene/solr' \
		REPO_SCONF=~ontohub/ontohub/solr/conf

	# deploy solr on tomcat (~150 MB archive + 0.5 MB the extracted solr.war)
	[[ ! -d ${SITEDIR}/tmp ]] && mkdir -p ${SITEDIR}/tmp
	cd ${SITEDIR}/tmp  || return 1
	[[ -e solr-${SOLR_VERS}.tgz ]] && X=${ file solr-${SOLR_VERS}.tgz ; }
	if [[ ! $X =~ 'gzip compressed data' ]]; then
		rm -f solr-${SOLR_VERS}.tgz
		curl -O ${SOLRBASE}/${SOLR_VERS}/solr-${SOLR_VERS}.tgz
	fi
	gunzip -c solr-${SOLR_VERS}.tgz | \
		tar xvf - --strip-components=2 \
			solr-${SOLR_VERS}/dist/solr-solrj-${SOLR_VERS}.jar
	mv solr-solrj-${SOLR_VERS}.jar /var/lib/tomcat7/webapps/solr.war || return 1
	chown tomcat7:tomcat7 /var/lib/tomcat7/webapps/solr.war

	for (( I=0; I < 300; I++  )); do
		[[ -d /var/lib/tomcat7/webapps/solr ]] && break
		sleep 0.2
	done
	# TBD: This is dangerous/works as long as the webapp doesn't get redeployed
	ln -sf ${REPO_SCONF} /var/lib/tomcat7/webapps/solr/conf
	chmod 0755 /var/log/tomcat7			# 0750 is too paranoid
	Log.info "$0 done."
}

function postOntohub {
	postInit || return $?
	typeset SCRIPT=etc/god-serv.sh OHOME=~ontohub X DB RAILS_ENV

	Log.info "$0 setup ..."
	if [[ ${BRANCH} == 'master' || ${BRANCH} == 'staging' ]]; then
		X='-P'
		DB='ontohub'
		RAILS_ENV='production'
	else
		X=''
		DB='ontohub_development'
		RAILS_ENV='development'
	fi
		
	Log.info "$0 setup ..."
	print '# Ontohub god (process manager)
description "Ontohub god"
start on (net-device-up and local-filesystems)
stop on runlevel [016]

respawn
setuid ontohub

exec '"${OHOME}/${SCRIPT}"' start --no-daemonize

pre-stop exec '"${OHOME}/${SCRIPT}"' stop'	>/etc/init/ontohub.conf

	# The pid stuff seems to be hardcoded into config/god/app.rb - who knows,
	# for what it is good. Also dumb upstart does not run a login shell even if
	# setuid is given. So no profiles are sourced in before this one starts ...
	[[ -d ${OHOME}/${SCRIPT%/*} ]] || mkdir -p ${OHOME}/${SCRIPT%/*}
	print '#!/bin/ksh93
HOME='"'${OHOME}'"'
RAILS_ENV='"${RAILS_ENV}"'
umask 002

# When fired via upstart, profiles get ignored
RB_PROFILE=/local/usr/ruby/.profile
[[ -z ${RBENV_ROOT} && -f ${RB_PROFILE} ]] && source ${RB_PROFILE}

cd ${HOME}/ontohub	# the repo clone

[[ -d ${HOME}/log ]] || mkdir ${HOME}/log
[[ -e log ]] || ln -s ${HOME}/log log
[[ -d tmp/pids ]] || mkdir -p tmp/pids
print $$ >tmp/pids/god.pid		# well, who knows ...
export RAILS_ENV HOME

if [[ $1 == "start" ]]; then
	shift
	exec ${HOME}/bin/god --config-file config/god/app.rb \
		--pid tmp/pids/god.pid --log-level debug --log ${HOME}/log/god.log "$@"
elif [[ $1 == "stop" ]]; then
	exec ${HOME}/bin/god terminate
fi
'	>${OHOME}/${SCRIPT}
	chmod 0755 ${OHOME}/${SCRIPT}

	DB=${ print 'SELECT COUNT(*) FROM ontology_file_extensions;' | \
			su - ontohub -c "psql ${DB}" 2>/dev/null ; }
	[[ -z ${DB} ]] && X+=' -R'		# a virgin db?

	# buid/install gems required by ontohub server app (~420 MB)
	[[ -n ${BRANCH} ]] && X+=" -b ${BRANCH}"
	su - ontohub -c "~admin/etc/oh-update.sh $X"

	service ontohub start
	Log.info "$0 done."
}

function postDb {
	postInit || return $?

	Log.info "$0 setup ..."
	service redis-server stop
	sed -e "/^dir / s,^.*,dir ${REDISDIR}," -i /etc/redis/redis.conf
	service redis-server start

	service postgresql stop

	typeset X=${ pg_config --bindir ; } Y Z DB SQL

	[[ ${BRANCH} == 'master' || ${BRANCH} == 'staging' ]] && DB='ontohub' \
		|| DB='ontohub_development,ontohub_test'

	[[ ! -d ${PSQLDIR}/main ]] && mkdir ${PSQLDIR}/main && \
		chown postgres:postgres ${PSQLDIR}/main
	[[ -f ${PSQLDIR}/main/PG_VERSION ]] || \
		su - postgres -c "$X/pg_ctl -D ${PSQLDIR}/main initdb"

	X=${ find /etc/postgresql -name pg_hba.conf ; }
	if [[ ! -e ${PSQLDIR}/pg_hba.conf ]]; then
		print "# see $X for details - per default reject inet connections"'
#TYPE	DATABASE	USER		ADDRESS		METHOD
local	all			postgres				peer map=sysops
local	'"${DB}"'	ontohub					peer map=ontohub
#host	'"${DB}"'	ontohub		127.0.0.1	md5
#host	'"${DB}"'	ontohub		::1/128		md5
'		>${PSQLDIR}/pg_hba.conf
	fi
	if [[ ! -e ${PSQLDIR}/pg_ident.conf ]]; then
		X="${X%/*}/pg_ident.conf"
		print "# see $X for details"'
#MAPNAME	SYSTEM-USERNAME	PG-USERNAME
sysops		postgres		postgres
sysops		admin			postgres
ontohub		admin			ontohub
ontohub		ontohub			ontohub
ontohub		webservd		ontohub
'		>${PSQLDIR}/pg_ident.conf
	fi

	X="${X%/*}/postgresql.conf"
	[[ -f $X && ! -f ${X}.orig ]] && mv $X ${X}.orig || rm -f $X
	if [[ ! -e ${PSQLDIR}/postgresql.conf ]]; then
		sed -e "/^data_directory/ s,=.*,= '${PSQLDIR}/main'," \
			-e "/^hba_file/ s,=.*,= '${PSQLDIR}/pg_hba.conf'," \
			-e "/^ident_file/ s,=.*,= '${PSQLDIR}/pg_ident.conf'," \
			${X}.orig >${PSQLDIR}/postgresql.conf
	fi
	ln -sf ${PSQLDIR}/postgresql.conf $X
	service postgresql start

	# do nothing, if db[s] already exists
	Z='create user ontohub;'
	SQL=''
	for Y in ${DB//,/ }; do
		X=${ su - postgres -c "psql -l $Y" 2>/dev/null ; }
		if [[ -z $X ]]; then
			SQL+="$Z"'
create database '"$Y"';
grant all on database '"$Y"' to ontohub;
'
		fi
		Z=''
	done
	[[ -n ${SQL} ]] && print "${SQL}" | su - postgres -c psql
	Log.info "$0 setup done."
}

function postApache {
	postInit || return $?

	Log.info "$0 setup ..."
	service apache2 stop

	[[ ! -d ${SITEDIR} ]] && { mkdir -p ${SITEDIR} || return 1 ; }
	cd ${SITEDIR} || return 1

	# (a) we do not rely on the debian crap and (b) put it into a safe area
	# TBD: for now we make it here manually - on Solaris we would just call our
	# httpd-setup.ksh -n ${SITEDIR##*/} \
	#		-s -u [-o] -c -O webadm -G staff -p 80 -P 443
	typeset X ADD CFDIR="${SITEDIR%/*}/conf" SITESUBNET=${ZIP}${ZNMASK} \
		SITECF="${CFDIR}/sites/${SITEDIR##*/}"

	[[ -d ${CFDIR}/sites ]] || mkdir -p ${CFDIR}/sites

	# on Ubuntu this is needed ...
	X=/etc/apache2/envvars
	[[ -e ${X}.orig ]] || cp -p $X ${X}.orig
	if [[ ! -e ${CFDIR}/envvars ]]; then
		sed -e "/^# envvars/ a\\APACHE_CONFDIR='${CFDIR}'" \
			/etc/apache2/envvars.orig >${CFDIR}/envvars
		# on linux this is bash ... =8-(
		ADD='APACHE_ULIMIT_MAX_FILES=`ulimit -H -n`\n'
		# Since webservice (httpd/passenger) and git service wanna write to
		# the same dirs, make sure they use a proper umask to avoid any trouble
		# (e.g. fs specifc ACLs, i.e. dropped POSIX draft vs. ZFS/NFS4 impl.)
		# or the need, to run the services in privileged mode.
		# dirs: 0777-002=0775   files: 0666-002=0664
		ADD+='umask 002\n'
		# avoid status 500 server errors (otherwise unix sockets would be used)
		ADD+='export _PASSENGER_FORCE_HTTP_SESSION="true"\n'
		# Hmm, some scripts call env ruby - so they need a path... =8-(
		ADD+="export PATH=${RBENV_ROOT}/shims:/usr/bin/:/bin\n"
		print -n "${ADD}" >>${CFDIR}/envvars
	fi
	ln -sf ${CFDIR}/envvars /etc/apache2/envvars
	# fix the debian shit
	sed -e '/maximum number of file descriptors/ { p; N; N; N ; N; N; s,.*,\[ -n \$ULIMIT_MAX_FILES \] \&\& ulimit -S -n \$ULIMIT_MAX_FILES, ; p; x; P; P; P; }' -i /usr/sbin/apache2ctl

	# damn: and this as well
	[[ -e ${CFDIR}/apache2.conf ]] || ln -s httpd.conf ${CFDIR}/apache2.conf

	# pure convinience
	[[ -d /var/www/cgi-bin ]] || mkdir /var/www/cgi-bin
	if [[ ! -x /var/www/cgi-bin/printenv ]]; then
		print '#!/bin/ksh93
print "Content-type: text/plain; charset=UTF-8\n\n"
set
'			>/var/www/cgi-bin/printenv
		chmod 0755 /var/www/cgi-bin/printenv
	fi

	# the common "minimal" set for all httpd servers
	[[ -e ${CFDIR}/httpd.conf ]] || cat>${CFDIR}/httpd.conf<<EOF
# For more information have a look at the default config file
# /etc/apache2/apache2.conf and http://httpd.apache.org/docs/

ServerRoot	"/usr/lib/apache2"
PidFile		\${APACHE_PID_FILE}
#			the default instance always listens to the loopback interface, only.
Listen		127.0.0.1:80

LoadModule	mpm_event_module		modules/mod_mpm_event.so
LoadModule	access_compat_module	modules/mod_access_compat.so
LoadModule	alias_module			modules/mod_alias.so
LoadModule	autoindex_module		modules/mod_autoindex.so
LoadModule	cgid_module				modules/mod_cgid.so
LoadModule	deflate_module			modules/mod_deflate.so
LoadModule	dir_module				modules/mod_dir.so
LoadModule	env_module				modules/mod_env.so
LoadModule	headers_module			modules/mod_headers.so
LoadModule	mime_magic_module		modules/mod_mime_magic.so
LoadModule	mime_module				modules/mod_mime.so
LoadModule	negotiation_module		modules/mod_negotiation.so
LoadModule	rewrite_module			modules/mod_rewrite.so
LoadModule	setenvif_module			modules/mod_setenvif.so
LoadModule	auth_basic_module		modules/mod_auth_basic.so
LoadModule	authn_core_module		modules/mod_authn_core.so
LoadModule	authz_core_module		modules/mod_authz_core.so
LoadModule	authz_host_module		modules/mod_authz_host.so
LoadModule	reqtimeout_module		modules/mod_reqtimeout.so

User		\${APACHE_RUN_USER}
Group		\${APACHE_RUN_GROUP}
ServerAdmin	webmaster+${ZNAME}@${ZDOMAIN}
ServerName	localhost

# StartServers:		initial number of server processes to start
# MinSpareThreads:	minimum number of worker threads which are kept spare.
# 					StartServers * MinSpareThreads = initial number of workers.
# MaxSpareThreads:	maximum number of worker threads which are kept spare
# ThreadsPerChild:	constant number of worker threads in each server process.
#					for proxy worker this also implies the max. number of
#					connections to the backend.
# MaxClients:		maximum number of simultaneous client connections
# MaxRequestsPerChild:	maximum number of requests a server process serves
# ServerLimit:		automatically determined == MaxClients/ThreadsPerChild + 1 

StartServers		1
MinSpareThreads		16
MaxSpareThreads		48
ThreadsPerChild		24
MaxClients			192
MaxRequestsPerChild	0

TypesConfig			/etc/mime.types
MIMEMagicFile		/etc/apache2/magic
EnableMMAP			on
EnableSendfile		on
Timeout				300
KeepAlive			on
KeepAliveTimeout	5
MaxKeepAliveRequests	10000
UseCanonicalName	on
ServerTokens		full
ServerSignature		on
HostnameLookups		on
Mutex				file:\${APACHE_LOCK_DIR} default

<IfModule reqtimeout_module>
	# Format: time to wait for the 1st byte in seconds, rate in Bytes per second
	RequestReadTimeout header=20-40,minrate=500
	RequestReadTimeout body=10,minrate=500
</IfModule>

<IfModule setenvif_module>
	# all other defaults refer to ancient software no-one should use anymore
	BrowserMatch	" Konqueror/4" redirect-carefully
</IfModule>

DirectoryIndex index.html index.html.var

<FilesMatch "^\.ht">
	Require all denied
</FilesMatch>

<Directory />
	Options -FollowSymLinks
	AllowOverride None
	Require all denied
</Directory>

DocumentRoot "/var/www/html"
<Directory "/var/www/html">
	Options +Indexes +MultiViews -FollowSymLinks
	AllowOverride None
	Require all granted
</Directory>

ScriptAlias /cgi-bin/printenv /var/www/cgi-bin/printenv
<Location "/cgi-bin/printenv">
	Require ip 127.0.0.1 ${SITESUBNET}
</Location>

ScriptAlias /cgi-bin/ "/var/www/cgi-bin/"
<Directory "/var/www/cgi-bin">
	AddHandler cgi-script .cgi
	AllowOverride None
	Options +SymLinksIfOwnerMatch
	Require all granted
</Directory>

LogLevel	warn
ErrorLog	\${APACHE_LOG_DIR}/error.log
LogFormat	"%h %{%F %T %z}t %X %I %O %B %D %u %>s \"%r\" \"%{Referer}i\" \"%{User-Agent}i\"" extended
CustomLog	"|/usr/bin/rotatelogs \${APACHE_LOG_DIR}/%Y%m%d-%H%M%S-access.log 2592000" extended env=!SSL_PROTOCOL

<IfModule cgid_module>
	ScriptSock	\${APACHE_LOG_DIR}/cgid.sock
</IfModule>

Alias /error/ "/usr/share/apache2/error/"
<Directory "/usr/share/apache2/error">
	AllowOverride None
	Options IncludesNoExec
	AddOutputFilter Includes html
	AddHandler type-map var
	Require all granted
	LanguagePriority de en fr es cs it ja ko nl pl pt-br ro sv tr
	ForceLanguagePriority Prefer Fallback
</Directory>
ErrorDocument 400 /error/HTTP_BAD_REQUEST.html.var
ErrorDocument 401 /error/HTTP_UNAUTHORIZED.html.var
ErrorDocument 403 /error/HTTP_FORBIDDEN.html.var
ErrorDocument 404 /error/HTTP_NOT_FOUND.html.var
ErrorDocument 405 /error/HTTP_METHOD_NOT_ALLOWED.html.var
ErrorDocument 408 /error/HTTP_REQUEST_TIME_OUT.html.var
ErrorDocument 410 /error/HTTP_GONE.html.var
ErrorDocument 411 /error/HTTP_LENGTH_REQUIRED.html.var
ErrorDocument 412 /error/HTTP_PRECONDITION_FAILED.html.var
ErrorDocument 413 /error/HTTP_REQUEST_ENTITY_TOO_LARGE.html.var
ErrorDocument 414 /error/HTTP_REQUEST_URI_TOO_LARGE.html.var
ErrorDocument 415 /error/HTTP_UNSUPPORTED_MEDIA_TYPE.html.var
ErrorDocument 500 /error/HTTP_INTERNAL_SERVER_ERROR.html.var
ErrorDocument 501 /error/HTTP_NOT_IMPLEMENTED.html.var
ErrorDocument 502 /error/HTTP_BAD_GATEWAY.html.var
ErrorDocument 503 /error/HTTP_SERVICE_UNAVAILABLE.html.var
ErrorDocument 506 /error/HTTP_VARIANT_ALSO_VARIES.html.var

IndexOptions	FancyIndexing FoldersFirst VersionSort NameWidth=* DescriptionWidth=*

Alias /icons/ "/usr/share/apache2/icons/"
<Directory "/usr/share/apache2/icons">
	Options Indexes MultiViews
	AllowOverride None
	Require all granted
</Directory>
AddIconByEncoding (CMP,/icons/compressed.gif) x-compress x-gzip
AddIconByType (TXT,/icons/text.gif) text/*
AddIconByType (IMG,/icons/image2.gif) image/*
AddIconByType (SND,/icons/sound2.gif) audio/*
AddIconByType (VID,/icons/movie.gif) video/*
AddIcon /icons/binary.gif .bin .exe
AddIcon /icons/binhex.gif .hqx
AddIcon /icons/tar.gif .tar
AddIcon /icons/world2.gif .wrl .wrl.gz .vrml .vrm .iv
AddIcon /icons/compressed.gif .Z .z .tgz .gz .zip
AddIcon /icons/a.gif .ps .ai .eps
AddIcon /icons/layout.gif .html .shtml .htm .pdf
AddIcon /icons/text.gif .txt
AddIcon /icons/c.gif .c
AddIcon /icons/p.gif .pl .py
AddIcon /icons/f.gif .for
AddIcon /icons/dvi.gif .dvi
AddIcon /icons/uuencoded.gif .uu
AddIcon /icons/script.gif .conf .sh .shar .csh .ksh .tcl
AddIcon /icons/tex.gif .tex
AddIcon /icons/bomb.gif core
AddIcon /icons/back.gif ..
AddIcon /icons/hand.right.gif README
AddIcon /icons/folder.gif ^^DIRECTORY^^
AddIcon /icons/blank.gif ^^BLANKICON^^
DefaultIcon /icons/unknown.gif
ReadmeName README.html
HeaderName HEADER.html
IndexIgnore .ht* *~ *# HEADER* RCS CVS *,v *,t

Include ${SITECF%/*}/extern.conf
# vim: syntax=apache ts=4 sw=4 sts=4 sr noet
EOF

	X=${CFDIR}/sites/pass
	if [[ ! -x $X ]]; then
		print '#!/bin/sh\necho unattended_boot_allows_now_pass' >$X
		chown webadm:webservd $X
		chmod 0770 $X
	fi
	for X in crt key ; do
		[[ ! -d ${CFDIR}/ssl.$X ]] && mkdir ${CFDIR}/ssl.$X
		chown webadm:webservd ${CFDIR}/ssl.$X
		[[ $X == 'key' ]] && ADD=0750 || ADD=0755
		chmod ${ADD} ${CFDIR}/ssl.$X
	done
	X=${CFDIR}/ssl.crt/hashCerts
	[[ ! -x $X ]] && cp -p ~admin/etc/hashCerts $X && chmod 0755 $X
	if [[ ! -e ${CFDIR}/ssl.crt/server.crt ]]; then
		ln -s /etc/ssl/private/ssl-cert-snakeoil.key ${CFDIR}/ssl.key/server.key
		ln -s /etc/ssl/certs/ssl-cert-snakeoil.pem ${CFDIR}/ssl.crt/server.crt
	fi
	${CFDIR}/ssl.crt/hashCerts

	print '# Basic/common SSL configuration
<IfModule !ssl_module>
	LoadModule	ssl_module				modules/mod_ssl.so
</IfModule>
<IfModule !socache_shmcb_module>
	LoadModule	socache_shmcb_module	modules/mod_socache_shmcb.so
</IfModule>
SSLRandomSeed			startup file:/dev/urandom 512
SSLRandomSeed			connect file:/dev/urandom 512
SSLPassPhraseDialog		exec:'"${CFDIR}"'/sites/pass

SSLSessionCache			shmcb:${APACHE_RUN_DIR}/ssl_scache(512000)
SSLSessionCacheTimeout	300
Mutex					sem
#SSLCipherSuite			ALL:!ADH:!kEDH:!EXPORT56:RC4+RSA:+HIGH:+MEDIUM:+LOW:+SSLv2:+EXP:+eNULL
# taken AS IS from original
SSLCipherSuite			EECDH+AES:AES128-GCM-SHA256:HIGH:!MD5:!aNULL:!EDH
SSLHonorCipherOrder		on
#SSLVerifyClient		require
#SSLVerifyDepth			5
SSLCertificateFile		'"${CFDIR}"'/ssl.crt/server.crt
SSLCertificateKeyFile	'"${CFDIR}"'/ssl.key/server.key
SSLCACertificatePath	'"${CFDIR}"'/ssl.crt
# taken AS IS from original
SSLProtocol				all -SSLv2

AddType application/x-x509-ca-cert	.crt
AddType application/x-pkcs7-crl		.crl

<FilesMatch "\.(cgi|shtml|phtml|php)$">
	SSLOptions +StdEnvVars
</FilesMatch>
<Directory "/var/www/cgi-bin">
	SSLOptions +StdEnvVars
</Directory>

LogFormat	"%h %{%F %T %z}t %X %I %O %B %D %{SSL_PROTOCOL}x %{SSL_CIPHER}x %u %>s \"%r\" \"%{Referer}i\" \"%{User-Agent}i\"" extendedssl
CustomLog	"|/usr/bin/rotatelogs ${APACHE_LOG_DIR}/%Y%m%d-%H%M%S-access.log 2592000" extendedssl env=SSL_PROTOCOL

# vim: ts=4 filetype=apache
'	>${CFDIR}/ssl.conf

	[[ -e ${CFDIR}/mime.types.extensions ]] || \
		cat>${CFDIR}/mime.types.extensions<<EOF
# Default icons come from /icons/* usually used by fancy indexing (20x22px)
AddDescription "Server Side Include file" .shtml
AddType text/html .shtml

AddDescription "Adobe Portable Document Format" .pdf
AddIcon /icons/pdf.gif .pdf

AddDescription "Eclipse classpath configuration file" .classpath
AddDescription "Eclipse project configuration file" .project
AddDescription "CVS configuration file for pathes to ignore" .cvsignore
AddDescription "Ant build properties customization file" build.properties
AddDescription "Ant build file" build.xml
AddType text/xml .classpath .project .xml
AddIcon /icons/screw1.gif .classpath .cvsignore .project .properties build.xml

AddDescription "Java Archive" .jar
AddType application/x-java-archive .jar
AddDescription "Java Network Lunch Protocol Application" .jnlp
AddType application/x-java-jnlp-file .jnlp
AddDescription "Java Archive Diff" .jardiff
AddType application/x-java-archive-diff .jardiff

AddDescription "tar archive" .tar
AddDescription "GZIP compressed archive" .gz
AddDescription "GZIP compressed tar archive" .tgz
AddType application/x-gzip .gz .tgz

AddDescription "Z compressed archive" .Z
AddType application/x-compress .Z

AddDescription "Bzip2 compressed archive" .bz2
AddType application/x-bzip2 .bz2
AddIcon /icons/compressed.gif .bz2

AddDescription "Proxy Auto Configuration file" .pac
AddType application/x-ns-proxy-autoconfig .pac
AddIcon /icons/world2.gif .pac

# vim: ts=4 filetype=apache
EOF

	# the common set for all sites hosted on this server
	[[ -e ${SITECF%/*}/extern.conf ]] || cat>${SITECF%/*}/extern.conf<<EOF
#Include ${CFDIR}/ssl.conf
Include ${CFDIR}/mime.types.extensions

<IfModule !status_module>
	LoadModule	status_module		modules/mod_status.so
	LoadModule	info_module			modules/mod_info.so
</IfModule>
ExtendedStatus On
<Location /server-status>
	SetHandler server-status
	Require ip 127.0.0.1 ${SITESUBNET}
</Location>
<Location /server-info>
	SetHandler server-info
	Require ip 127.0.0.1 ${SITESUBNET}
</Location>

<IfModule !include_module>
	LoadModule	include_module		modules/mod_include.so
</IfModule>
<IfModule !rewrite_module>
	LoadModule	rewrite_module		modules/mod_rewrite.so
</IfModule>
#<IfModule !proxy_module>
#	LoadModule	proxy_module				modules/mod_proxy.so
#</IfModule>
#<IfModule !proxy_http_module>
#	LoadModule	proxy_http_module			modules/mod_proxy_http.so
#</IfModule>
#<IfModule !lbmethod_byrequests_module>
#	LoadModule	lbmethod_byrequests_module	modules/mod_lbmethod_byrequests.so 
#</IfModule>
#<IfModule !slotmem_shm_module>
#	# required by proxy_balancer_module
#	LoadModule	slotmem_shm_module			modules/mod_slotmem_shm.so
#</IfModule>
#<IfModule !proxy_balancer_module>
#	LoadModule	proxy_balancer_module		modules/mod_proxy_balancer.so
#</IfModule>
#<IfModule !imagemap_module>
#	LoadModule	imagemap_module				modules/mod_imagemap.so
#</IfModule>
#<IfModule !asis_module>
#	LoadModule	asis_module					modules/mod_asis.so
#</IfModule>
<IfModule !expires_module>
	LoadModule	expires_module		modules/mod_expires.so
</IfModule>

AddEncoding gzip .gz

#Include ${RB_ETC}/passenger.conf

Listen ${ZIP}:80

<IfModule ssl_module>
	SSLEngine Off
</IfModule>
<VirtualHost ${ZIP}:80>
	Include ${SITECF}
</VirtualHost>
<IfModule ssl_module>
	Listen ${ZIP}:443
	<VirtualHost ${ZIP}:443>
		SSLEngine on
		Include ${SITECF}
	</VirtualHost>
</IfModule>

# vim: syntax=apache ts=4 sw=4 sts=4 sr noet
EOF

	# website specifics
	[[ -e ${SITECF%/*}/template.conf ]] || cat>${SITECF%/*}/template.conf<<EOF
# Generiert von template.conf mittels:
# gsed -e "s/@\NODENAME@/@NODENAME@/g" -e "s/@\DOMAIN@/@DOMAIN@/g" template.conf
# 
ServerAdmin webmaster+@NODENAME@@@DOMAIN@
ServerName @NODENAME@.@DOMAIN@
ServerAlias @NODENAME@
ServerAlias @DOMAIN@

#AddOutputFilter INCLUDES .shtml
#AddHandler send-as-is asis

# 1 day logfile rotation
CustomLog	\${APACHE_LOG_DIR}/@NODENAME@.@DOMAIN@/access.log extended env=!SSL_PROTOCOL
<IfModule ssl_module>
CustomLog	\${APACHE_LOG_DIR}/@NODENAME@.@DOMAIN@/ssl.log extended env=SSL_PROTOCOL
</IfModule>
ErrorLog	\${APACHE_LOG_DIR}/@NODENAME@.@DOMAIN@/error.log
<IfModule rewrite_module>
	LogLevel rewrite:error
</IfModule>
#<IfModule passenger_module>
#	PassengerEnabled On
#	PassengerDebugLogFile \${APACHE_LOG_DIR}/@NODENAME@.@DOMAIN@/passenger.log
##	PassengerLogLevel 7
#	PassengerAppEnv production
## taken AS IS from the original config
##	Header always unset "X-Powered-By"
##	Header always unset "X-Runtime"
#	SetEnv RUBY_GC_MALLOC_LIMIT 59000000
#	SetEnv RUBY_GC_HEAP_FREE_SLOTS 600000
#	SetEnv RUBY_GC_HEAP_INIT_SLOTS 100000
#</IfModule>

<IfModule rewrite_module>
	RewriteEngine On
	RewriteRule ^/server-   -   [L]
    
	RewriteCond %{HTTP_HOST} !=@NODENAME@.@DOMAIN@
	RewriteCond %{HTTP_HOST} !=@NODENAME@
	RewriteCond %{HTTP_HOST} !=localhost
	RewriteCond %{HTTPS} =on
	RewriteRule ^/(.*)  https://@NODENAME@.@DOMAIN@/$1 [R=301,L]
	RewriteCond %{HTTP_HOST} !=@NODENAME@.@DOMAIN@
	RewriteCond %{HTTP_HOST} !=@NODENAME@
	RewriteCond %{HTTP_HOST} !=localhost
	RewriteCond %{HTTPS} !=on
	RewriteRule ^/(.*)  http://@NODENAME@.@DOMAIN@/$1  [R=301,L]
</IfModule>

DocumentRoot ${SITEDIR%/*}/@NODENAME@.@DOMAIN@/htdocs
<Directory "${SITEDIR%/*}/@NODENAME@.@DOMAIN@/htdocs">
	AddType text/html .inc
	SetEnvIf Request_URI \.(en|de)\$ prefer-language=
	LanguagePriority de en
	ForceLanguagePriority Prefer Fallback
	AllowOverride AuthConfig Limit
	Options +Indexes +Includes +MultiViews
	Require all granted
</Directory>

# see ../httpd.conf
ScriptAlias /cgi-bin/printenv /var/www/cgi-bin/printenv

ScriptAlias	/cgi-bin/ ${SITEDIR%/*}/@NODENAME@.@DOMAIN@/cgi-bin/
<Directory "${SITEDIR%/*}/@NODENAME@.@DOMAIN@/cgi-bin">
	Require all granted
</Directory>

# NOTE:
# Actually using context aka app dirs (i.e. /$appName ) is very smart and
# should always be used. Unfortunately passenger (at least version 4.x) is
# buggy (see https://github.com/phusion/passenger/issues/1315 ) and needs to be
# forced to use TCP instead of UNIX sockets to workaround the bugs (Server
# Errors - Status 500 - on reload/every 2nd click, unless caching gets disabled,
# which is even worse. Also this fixes the ontohub.png image not found problem).
# And in turn if TCP sockets are forced, context dirs do not work anymore
# (another bug?). So to have a reliable app one can't neither use fast/cheap
# unix sockets nor app context dirs like this:
#Alias /@appName@/ @appDir@/public/
#<Directory @appDir@/public>
#	Options -MultiViews +SymLinksIfOwnerMatch
#	Require all granted
#</Directory>
#<Location /@appName@/>
#	PassengerBaseURI /@appName@
#	PassengerAppRoot @appDir@
#	PassengerAppEnv production
#</Location>

#<Directory "/web">
#	AddType text/plain .sh
#	AddIcon /icons/patch.gif .patch
#</Directory>

#<IfModule ssl_module>
#	SSLCertificateFile ${CFDIR}/ssl.crt/@NODENAME@.@DOMAIN@.crt
#	SSLCertificateKeyFile ${CFDIR}/ssl.key/@NODENAME@.@DOMAIN@.key
#</IfModule>

# vim: ts=4 filetype=apache
EOF

	[[ ! -d ${SITEDIR}/htdocs ]] && mkdir -p ${SITEDIR}/htdocs
	[[ ! -d ${SITEDIR}/cgi-bin ]] && mkdir -p ${SITEDIR}/cgi-bin
	[[ ! -d ${SITEDIR}/etc ]] && mkdir -p ${SITEDIR}//etc

	(	# avoid possible side effects
		. /etc/apache2/envvars
		chmod 0755 ${APACHE_LOG_DIR}		# 0750 is too paranoid
		rm -f ${APACHE_LOG_DIR}/*			# remove the bloat
		[[ -d ${APACHE_LOG_DIR}/${ZNAME}.${ZDOMAIN} ]] || \
			mkdir -p ${APACHE_LOG_DIR}/${ZNAME}.${ZDOMAIN}
	)

	sed -e '/passenger.conf/ s,^#,,' -i ${SITECF%/*}/extern.conf

	if [[ ! -e ${SITECF} ]]; then
		sed -e "s,@NODENAME@,${ZNAME},g" \
			-e "s,@DOMAIN@,${ZDOMAIN},g" ${SITECF%/*}/template.conf >${SITECF}

		# ontohub specials
		typeset APPBASE='/local/home/ontohub/ontohub/public' APPNAME='ruby' \
			RENV='development'
		[[ ${BRANCH} == 'master' || ${BRANCH} == 'staging' ]] && \
			RENV='production'
	
		# context apps do not work dueto bogus passenger (4.x)
#		sed -e "/^#Alias \/@appName@/,/^#<\/Location/ { s,^#,, ; s,@appName@,${APPNAME}, ; s,@appDir@,${APPBASE%/public}, }" \
#		-i ${SITECF}

		# so map the app completely to /
		sed -r -e "/^DocumentRoot/ s,^.*,DocumentRoot ${APPBASE}," \
			-e "/^<Directory .*\/htdocs\"?/ s,^.*,<Directory \"${APPBASE}\">," \
			-e '/^DocumentRoot/,/^<\/Directory>/ s,\+MultiViews,-MultiViews +SymLinksIfOwnerMatch,' \
			-i ${SITECF}

		# maintenance.txt is hardcoded into lib/capistrano/tasks/maintenance.cap
		# and git/lib/git_shell.rb - prefer to have the rewrite rules in the
		# main config instead of a .htaccess somewhere in the wild
		sed -e "/PassengerAppEnv/ s,production,${RENV}," \
			-e '/#<IfModule passenger_module/,/#<\/IfModule/ s,^#,,' \
			-e '/^DocumentRoot/ {
a\
<Location /> \
	# no trailing slashes \
	RewriteCond %{REQUEST_URI} .+/$ \
	RewriteRule ^(.+)/$ /$1 [R=301,L] \
 \
	RewriteCond %{DOCUMENT_ROOT}/../data/maintenance.txt -f \
	RewriteRule .* /503.html [R=503,L] \
</Location>
}'			-i ${SITECF}

		print '
# taken AS IS from the original
<IfModule deflate_module>
	<IfModule mod_filter.c>
		# these are known to be safe with MSIE 6
		AddOutputFilterByType DEFLATE text/html text/plain text/xml

		# everything else may cause problems with MSIE 6
		AddOutputFilterByType DEFLATE text/css
		AddOutputFilterByType DEFLATE application/x-javascript application/javascript application/ecmascript
		AddOutputFilterByType DEFLATE application/rss+xml
	</IfModule>
</IfModule>
'			>>${SITECF}
	fi

	chown -R webadm:staff ${SITEDIR}
	#chown -R ontohub:webservd ${SITEDIR}

	service apache2 start
	Log.info "$0 setup done."
}

function postGit {
	#postInit || return $?

	Log.info "$0 setup ..."
	Log.warn "$0: TBD"
	# see config/initializers/paths.rb , app/models/repository/symlink.rb ,
	# lib/tasks/databases.rake -> 'repositories', 'git_daemon' and 'commits'
	# are hardcoded data sub dirs. script/backup is another consumer, however,
	# its CLI usage is not POSIX conform and requires other fixes anyway ...
	print 'start on startup
stop on shutdown
#setuid git
#setgid webservd
# why nobody:nogroup ?
setuid nobody
setgid nogroup
exec /usr/bin/git daemon --reuseaddr --export-all --syslog \
	--base-path='"${GITDATA}/repositories"'
respawn'	>/etc/init/git-serv.conf

	typeset GITSSH="${GITDATA}/.ssh"
	[[ -f ~git/.ssh/authorized_keys2 && ! -f ${GITSSH}/authorized_keys2 ]] && \
		cp -p ~git/.ssh/authorized_keys2 ${GITSSH}/
	ln -sf ${GITSSH}/authorized_keys2 ~git/.ssh/authorized_keys2
	# see coments in postApache
	chmod 0660 ${GITSSH}/authorized_keys2
	print 'umask 002' >>~git/.profile
	
	service git-serv start
	Log.info "$0 setup done."
}

function normalizeRubyVersion {
	[[ -z $1 || ! -f $1 ]] && return
	typeset X F=$1
	# muhhhh - need to normalize to major.minor.tiny
	X=$(<$F)
	F="${X##~(E)[^0-9]}"
	X=${X%-*}
	[[ -z $X ]] && return
	X=( ${X//./ } )
	for (( I=${#X[@]} ; I < 3 ; I++ )); do
		X+=( '0' )
	done
	F="${X[@]}"
	print "${F// /.}"
}

function postInit {
	(( INIT )) && return 0
	[[ -d ~ontohub/ontohub ]] || return 1
	
	# let this file dictate the ruby version to install - anyway, it is so
	# hard to write down the correct version number ... - muhhh
	typeset X=${ normalizeRubyVersion ~ontohub/ontohub/.ruby-version ; }
	[[ -n $X ]] && RUBY_VERS="$X"
	grep -q _solr ~ontohub/ontohub/Gemfile && HAS_SOLR=1
	Log.info "Using ruby version '${RUBY_VERS}'."
	RB_ETC="${RBENV_ROOT}/versions/${RUBY_VERS}/etc"
	X=$(<~ontohub/ontohub/.git/HEAD)
	[[ $X =~ '/' ]] && BRANCH="${X##*/}"
	INIT=1
}

function postInstall {
	Log.info "Running $0 ..."
	typeset F X PKGS='redis-server hets-server-core'

	# Add redis-server daily and hets repositories
	X='http://ppa.launchpad.net/chris-lea/redis-server/ubuntu'
	print "deb $X ${LNX_CODENAME} "'main\ndeb-src'" $X ${LNX_CODENAME} main" \
		>/etc/apt/sources.list.d/redis.list
	X='http://ppa.launchpad.net/hets/hets/ubuntu'
	print "deb $X ${LNX_CODENAME} "'main\ndeb-src'" $X ${LNX_CODENAME} main" \
		>/etc/apt/sources.list.d/hets.list
	apt-key adv --keyserver keyserver.ubuntu.com \
		--recv-keys 3FF4B01F2A2314D8 B9316A7BC7917B12
	apt-get update

	# just clone the ontohub server app repository (~35 MB)
	[[ -n ${BRANCH} ]] && X="-b ${BRANCH}" || X=''
	[[ ${BRANCH} == 'master' || ${BRANCH} == 'staging' ]] && X+=' -P'
	# pull/checkout to get the needed ruby version
	su - ontohub -c "~admin/etc/oh-update.sh $X -u" 
	postInit || return $?	# because this may change pkg selection
	(( HAS_SOLR )) && PKGS+=' tomcat7 tomcat7-admin'

	# hets and tomcat need JRE, which in turn needs a running zone (pkg assembly
	# issue). redis-server does not, but putting it here saves an additional
	# apt-get install ...
	Log.info "Adding ${PKGS} ..."
	apt-get install --no-install-recommends -y ${PKGS}

	postDb
	postSolr	# Gets a symlink to a repo clone sub dir!
	postRuby
	postApache	# Order! We include the postRuby generated passenger.conf
	postOntohub	# Order! Deps on postRuby
	postGit

	# hets -update ==> is history @since 2014-11-18
	Log.info "$0 done."
}

# prepare stuff for export
PSQLDIR=${DATADIR[psql].z_dir}
REDISDIR=${DATADIR[redis].z_dir}
GITDATA=${DATADIR[git].z_dir}
SITEDIR=/${DATADIR[sites].z_pool#*/}/${ZNAME}.${ZDOMAIN}
integer HAS_SOLR=0

FN=' normalizeRubyVersion'
for X in ${ typeset +f ; } ; do [[ $X =~ ^post ]] && FN+=" $X" ; done

ZSCRIPT='#!/bin/ksh93\n. /local/home/admin/etc/log.kshlib\n\n' 
ZSCRIPT+='integer INIT=0 JOBS=${ grep ^processor /proc/cpuinfo | wc -l ; }\n'
ZSCRIPT+="${ typeset -p PSQLDIR REDISDIR GITDIR SITEDIR LNX_CODENAME SOLR_VERS \
	ZNAME ZDOMAIN ZIP ZNMASK SOLR_VERS RUBY_VERS RBENV_ROOT \
	GITDATA BRANCH HAS_SOLR ; }\n"
ZSCRIPT+='RB_ETC="${RBENV_ROOT}/versions/${RUBY_VERS}/etc"\t#see postInit\n'
ZSCRIPT+="${ typeset -f -p ${FN} ; }\n\n"
ZSCRIPT+='#typeset -ft ${ typeset +f ; }\n\n'
X="${FN// /|}"
ZSCRIPT+='[[ -z $1 ]] && Log.fatal "Usage: $0 {postInstall'"${X//|postInstall}"'}" && exit 1\n$1'
print "${ZSCRIPT}" >${ZROOT}/local/home/admin/etc/post-install2.sh


# fire the postinstall stuff inside
zlogin ${ZNAME} /bin/ksh93 /local/home/admin/etc/post-install2.sh postInstall

Log.info 'Zone should be up and running.'

# vim: ts=4 sw=4 filetype=sh
