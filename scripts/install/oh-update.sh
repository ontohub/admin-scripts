#!/bin/ksh93

unset CFG LC_ALL LANG LANGUAGE

MY_ORG="© 2012-${ date +%Y ; } Universität Magdeburg and Universität Bremen"
MY_NAME='Ontohub'
# If unset, local sendmail delivery will be used, otherwise direct smtp gets
# configured, i.e. talk directly non-STARTTLS SMTP to ${MAIL_GW} on port 25
MAIL_GW='mail'
# the a priori default 'staging' is dead meat, so we need to set it explicitly
DEFAULT_BRANCH='staging.ontohub.org'
# The port the web application should use (the httpd proxy connects to)
WEBAPP_PORT=3000
# The directory, which contains bin/hets-server and lib/hets-server etc.
HETS_DESTDIR=/usr
export PGHOST='/var/run/postgresql'

typeset -A CFG
export LC_CTYPE=C LC_MESSAGES=C LC_COLLATE=C LC_TIME=C GIT=${ whence git ; }
integer HAS_SOLR=0

CFG[url]='https://github.com/ontohub/ontohub.git'
CFG[repo]=${HOME%%/}/ontohub CFG[dest]=${HOME%%/}
CFG[datadir]='/data/git'

LIC='[-?$Id: oh-update.sh,v 0a7ae1797527 2015-02-26 17:49:11Z jel+opengrok $ ]
[-copyright?Copyright (c) 2014 Jens Elkner. All rights reserved.]
[-license?CDDL 1.0]'
typeset -r SDIR=${.sh.file%/*} FPROG=${.sh.file} PROG=${FPROG##*/}

for H in log.kshlib man.kshlib ; do
	X=${SDIR}/etc/$H
	[[ -r $X ]] && . $X && continue
	X=${ whence $H; }
	[[ -z $X && -r ~admin/etc/$H ]] && X=~admin/etc/$H
	[[ -z $X ]] && print "$H not found - exiting." && exit 1
	source $X 
done
unset H

function showUsage {
	typeset WHAT="$2"
	getopts -a "${PROG}" "${ print ${Man.FUNC[${WHAT}]}; }" OPT --man
}

function normalizeRubyVersion {
    [[ -z $1 || ! -f $1 ]] && return
    typeset X F=$1
    # muhhhh - need to normalize to major.minor.tiny
    X=$(<$F)
    F="${X#~(E)[^0-9]*}"
    X=${F%-*}
    [[ -z $X ]] && return
    X=( ${X//./ } )
    for (( I=${#X[@]} ; I < 3 ; I++ )); do
        X+=( '0' )
    done
    F="${X[@]}"
	print "${F// /.}"
}

function getRepoRubyVersion {
	cd "${CFG[repo]}" || return 4
	typeset X=$(<.ruby-version) Y=${ normalizeRubyVersion .ruby-version ; }
	[[ -n $Y ]] && print "$Y"
	cd - >/dev/null
}

function firstTimeChanges {
	Log.info 'Applying 1st time aka only once modifications ...'

	# base config for the first time, only.
	typeset A B HNAME SET RUBY=${ whence ruby ; }
	integer I
	A=( ${ getent hosts ${ hostname ; } ; } )
	for (( I=1 ; I < ${#A[@]}; I++ )); do
		B=( ${A[I]//./ } )
		(( ${#B[@]} > 1 )) && HNAME="${A[I]}" && break
	done
	I=0
	SET=''
	for X in ~(N)${HOME}/etc/*.patch ; do
		#patch -p1 -i $X
		git apply $X
		if (( CFG[commit] )); then
			git status -s | while read A B Y ; do
				[[ $A == '??' && -f $B ]] && SET+="$B "
			done
			[[ -n ${SET} ]] && git add ${SET}
			A=${ git commit -a -m "${X##*/}" 2>&1 ; }
			(( $? )) && print "$A" || print "Patch ${X##*/} applied"
		else
			print "Patch ${X##*/} applied"
		fi
	done
	# oh my goodness, this stuff is whitespace sensitive!
	sed -e '/\.development-state/ { p; s,\.dev.*,  display: none, }' \
		-i app/assets/stylesheets/navbar.css.sass
	# when ~ontohub/ontohub/git/bin/git-shell gets fired, no shell profiles are
	# read and thus env ruby would not found a ruby not installed in /usr/bin
	sed -i -e "1 s,^.*,#\!${RUBY}," git/bin/git-shell

	[[ Gemfile -nt Gemfile.lock ]] && rm Gemfile.lock

	# actually we could use config/settings/{production,...}.local.yml
	# but we do not wanna have even more files to maintain - keep it flat
	[[ ${CFG[renv]} == 'production' ]] && \
		SET='log_level: warn\nconsider_all_requests_local: false' || \
		SET='#log_level: debug\nconsider_all_requests_local: true'

	SET+="\nfooter:"
	SET+="\n  - text: ${MY_ORG}"
	SET+="\n  - text: About"
	SET+="\n    href: http://wiki.ontohub.org/"
	SET+="\n  - text: Sources"
	SET+="\n    href: https://github.com/ontohub/ontohub"
	SET+="\n\nname: ${MY_NAME}"
	if [[ -n ${HNAME} ]]; then
		case "${CFG[branch]}" in
			master)					SET+=' dead' ;;
			ontohub.org)			;;
			staging)				SET+=' dead β' ;;
			staging.ontohub.org)	SET+=' β' ;;
			development)			SET+=' dead α' ;;
			*)						SET+=' α' ;;
		esac
		X='@'
		# hook for inofficial zones
		[[ ${HNAME#*.} == 'ontohub.org' || \
			! ${ZNAME} =~ ^(www|staging|develop)$ ]] && \
			HNAME="${HNAME%%.*}.iws.cs.ovgu.de" && X="+oh-${HNAME%%.*}@"

		Y=${HNAME#*.}
		SET+="\nhostname: ${HNAME}"
		SET+="\nexception_notifier:"
		SET+="\n  sender_address: webservd@${HNAME}"
		SET+="\n  email_prefix: '[ontohub ex]'"
		SET+="\n  exception_recipients:\n  - ex${X}${Y}"
		# Current debian/ubuntu sendmail package is a horror pain in the ass!!!
		# Wenn Leute mit Stroh im Kopf mit Feuer spieln, wird's brenzlig ... 
		# So for now direct delivery:
	fi
	SET+='\naction_mailer:\n  delivery_method: smtp'

	# cookie encryption: overwrite config/initializers/secret_token.rb
	#X=${ ~ontohub/bin/rake secret ; }  # no way - cyclic ruby dependency
	X=' bootstrap.log: lastlog: auth.log: dmesg'
	X=${ openssl rand -hex -rand ${X// /\/var/\/log\/} 64 ; }
	[[ -n $X ]] && SET+="\n\nsecret_token: $X"

	# correct/skip unused pathes
	SET+='\n
hets_path: !str /usr/bin/hets-server
hets_lib: !str /usr/lib/hets-server/hets-lib
hets_owl_tools: !str /usr/lib/hets-server/hets-owl-tools'

	# See also ~admin/etc/post-install2.sh (postGit()) - "COW"
	print "${SET}" >config/settings.local.yml

	# For more or less modern, i.e. thread aware impl.s like JRuby or
	# Rubinius one would probably start with 1 or #CPUs workers,
	# #STRANDs/#CPUs as #MaxThreads and #MaxThread/4 as #MinThreads per
	# worker. Unfortunately we currently use MRI (which uses python like
	# model, i.e. thread == process), and thus threads are useless
	# => we need heavyweight workers to distribute the load/to be able
	# to take advantage of the available strands. Note that wrt. current
	# staging version (2014-12) one worker uses ~275 MiB RAM (RSS)!
	#
	# Also note, that - if one uses apache httpd in mpm-worker mode (what
	# we and usually all smart people do) infront of puma, the number of the
	# httpd setting 'ThreadsPerChild' is directly related to puma's
	# #Workers (or for thread aware impl.s to #Worker*#MaxThreads). I.e.
	# in the apache conf there is exactly one 'ProxyPass*' directive, which
	# causes a request to be passed to puma. Since each 'ProxyPass*' gets
	# managed by a single worker, this in turn means, that exactly ONE
	# apache worker aka process will be used to proxy all related requests.
	#
	# And since apache httpd uses for each connection a single thread, it
	# should be clear, that if 'ThreadsPerChild=24' is set (which is the
	# default - see http://localhost/server-info?event.c), it is - at least
	# in our heavy weight scenario - a waste of resources, if we instruct
	# puma to use more than 24 workers.
	integer STRANDS=${ nproc ; } THREADS=1 MINTHREADS=1 CPUS
	if (( 0 )); then
		CPUS=${ grep 'physical id' /proc/cpuinfo|sort -u|wc -l ; }
		integer CORES=${ grep 'core id' /proc/cpuinfo|sort -u|wc -l ; }
		(( THREADS=STRANDS/CPUS ))
		(( THREADS < 2 )) && THREADS=4
		(( CPUS < 1 )) && CPUS=1
		(( MINTHREADS=THREADS/4 ))
	else
		(( CPUS=STRANDS*0.75 ))
	fi

	# defaults are ok - just adjust the workers
	sed -i -e "/^workers/ s,^.*,workers ${CPUS}," config/puma.rb

	# don't call dangerous scripts, which may destroy data unintentionally, or
	# invoke sudo behind the scene, or seem to be simply overhead
	chmod 0644 script/{install-on-ubuntu,backup,rails} 2>/dev/null

}

function updateRepo {
	typeset OUT='' X Y
	integer PULL=1

	if [[ ! -d ${CFG[repo]%/*} ]]; then
		mkdir -p ${CFG[repo]%/*} || return 1
	fi
	cd  "${CFG[repo]%/*}" || return 2

	# clone if not already done
	if [[ ! -d ${CFG[repo]} ]]; then
		${GIT} clone ${CFG[url]} ${CFG[repo]##*/} || return 3
		[[ -z ${CFG[branch]} ]] && CFG[branch]="${DEFAULT_BRANCH}"
		PULL=0
	fi

	cd "${CFG[repo]}" || return 4
	[[ -f .git/HEAD ]] && OUT=$(<.git/HEAD)
	if [[ ${OUT} =~ "/" ]]; then
		OUT="${OUT##*/}"
	else
		Log.fatal "'${PWD}' exists but it does not seem to be a git repository."
		return 3
	fi
	# [[ ! ${OUT} =~ ^(master|staging)(\.ontohub\.org)?$ ]] && \
	#	CFG[renv]='development
	[[ -z ${CFG[renv]} ]] && CFG[renv]='production'

	if [[ -n ${CFG[branch]} && ${OUT} != ${CFG[branch]} ]]; then
		Log.info "Switching branch from '${OUT}' to '${CFG[branch]}' ..."
		${GIT} checkout ${CFG[branch]} || return 5
	else
		Log.info "Using branch '${OUT}' ..."
	fi
	if (( PULL )); then
		Log.info "Fetching '${CFG[repo]##*/}' updates ..."
		OUT=${ ${GIT} pull 2>&1 ; }
		if (( $? )); then
			[[ ${OUT} =~ unable\ to\ connect\ to\ github.com ]] && \
				OUT='Connection to github.com failed.'
			Log.fatal "${OUT}"
			return 6
		fi
		Log.info "'${CFG[repo]##*/}' is up to date."
	fi
	CFG[head]=${ ${GIT} rev-parse HEAD ; }
	[[ -z ${CFG[head]} ]] && \
		Log.warn 'Unable to determine the ID of the current HEAD.'

	# At least on Ubuntu amd64 ruby whines about unspecific versions like 2.1
	X=$(<.ruby-version)
	Y=${ normalizeRubyVersion .ruby-version ; }
	[[ -n $X && $X != $Y ]] && \
		Log.warn "Changing incorrect .ruby-version '$X' to '$Y'!" && \
		print "$Y" >.ruby-version

	[[ ! -e config/settings.local.yml ]] && firstTimeChanges

	# the running webapp wanna write its {production|development|sidekiq}.log
	# here but the build process and whatever else as well  =8-(
	[[ -e log ]] || { mkdir log || return 14 ; }
	X=${CFG[renv]}
	touch log/${X}.log
	# god.log comes from the god-serv service (is relocatable)
	[[ ! -e ~/log ]] && mkdir ~/log
	chmod g+w log log/${X}.log ~/log

	return 0
}

function buildGems {
	typeset X Y A RUBY=${ whence ruby ; }
	integer COMMIT=0

	[[ -z ${RUBY} ]] && Log.fatal "No 'ruby' installed?" && return 1
	cd "${CFG[repo]}" || return 4
	# actually there is no need to comit if Gemfile is properly constructed...
	[[ -e Gemfile.lock ]] || COMMIT=1

	A=( ${ ${RUBY} -e 'puts RUBY_VERSION' 2>/dev/null ; } )
	Y=${ getRepoRubyVersion ; }
	if [[ -z $A || $A != $Y ]]; then
		[[ -z $A ]] && cd /		# need the sys defaults
		CFG[rvers]=${ ${RUBY} -e 'puts RUBY_VERSION' 2>/dev/null ; }
		Log.warn "The required ruby version '$Y' seems not to be installed." \
			"You can use '${CFG[rvers]}' when you change the content of your" \
			'.ruby-version file accordingly.'
		return 1
	fi
	CFG[rvers]="$A"

	A=( ${ ${RUBY} -e 'puts Gem.user_dir' 2>/dev/null; } )
	[[ -z $A ]] && \
		Log.warn 'Unable to determine ruby gem version.' && return 2
	CFG[gvers]="${A##*/}"
	
	A=( ${ bundler version 2>/dev/null ; } )
	[[ -z $A ]] && \
		Log.fatal "The ruby gem 'bundler' is required but was not found. Use" \
			"'gem install bundler' to install it and make sure, that your" \
			"PATH env variable is properly set, so that it can be found." && \
		return 3
	CFG[bvers]="${A[-1]}"

	export RAILS_ENV=${CFG[renv]}

	[[ ${RAILS_ENV} == 'production' ]] && X='vendor/bundle' || X='../ruby'
	if [[ -f ${CFG[dest]}/VERSION && -d $X ]]; then
		A=( $(<${CFG[dest]}/VERSION) )
		if [[ $A == "${CFG[head]}@${CFG[rvers]}@${CFG[gvers]}@${CFG[bvers]}" ]]
		then
			Log.info 'Gems are already up to date. Nothing to do.'
			return 0
		fi
	fi

	Log.info 'Trying to build ontohub gems ...'
	# discard any settings from previous runs (especially BUNDLE_WITHOUT:)
	rm -f .bundle/config

	# 1693M
	if [[ ${RAILS_ENV} == 'production' ]]; then
		A=(
			'--without' 'development' 'test' #'deployment'
		)
		[[ -f Gemfile.lock ]] && A+=( '--deployment' )
		# what the heck ...
		sed -e '/system / s,-v ,,' -i lib/tasks/sidekiq.rake
	else
		unset A
		sed -e '/system / s, -L, -v -L,' -i lib/tasks/sidekiq.rake
	fi
	integer JOBS=1
	[[ ${ uname -s ; } == 'SunOS' ]] && JOBS=${ psrinfo | wc -l ; } || \
		JOBS=${ grep ^processor /proc/cpuinfo | wc -l ; }
	(( JOBS > 1 )) && A+=( "--jobs=${JOBS}" )

	# we do not want unmaintained libxml/libxslt
	bundle config build.nokogiri --use-system-libraries
	
	# update the Gemfile.lock file and actually build the gems
	bundler install --path="${CFG[dest]}" "${A[@]}" || return $?
	(( COMMIT && CFG[commit] )) && \
		git commit -m 'Gemfile.lock bundler update' Gemfile.lock

	# for convinience put the tools into a std path
	[[ -d ~/bin ]] || mkdir ~/bin
	[[ -d ~/bin ]] && bundler install --binstubs ~/bin

	X=${ umask ; }
	umask 002	# allow webservd to update e.g. tmp/cache/*
	# NOTE: W/o having RAILS_ENV set, it assumes RAILS_ENV=production ...
	~/bin/rake assets:precompile

	# recommended by builder doc - no clue, whether it makes a diff
	[[ -d shared ]] || mkdir shared
	ln -sf ../vendor/bundle shared/vendor_bundle

	# stamp this build
	print "${CFG[head]}@${CFG[rvers]}@${CFG[gvers]}@${CFG[bvers]}" \
		>${CFG[dest]}/VERSION
	umask $X
}

function resetDb {
	cd "${CFG[repo]}" || return 4

	Log.info 'Resetting database ...'

	export RAILS_ENV=${CFG[renv]}
	typeset DB='ontohub' DBUSER='ontohub'
	[[ ${RAILS_ENV} != 'production' ]] && DB+='_development'

	redis-cli flushdb
	# see http://blog.endpoint.com/2012/10/postgres-system-triggers-error.html
	#	http://stackoverflow.com/questions/7805558/how-to-disable-triggers-in-postgresql-9
	if (( HAS_SOLR )); then
		~/bin/rake db:migrate:reset
		~/bin/rake sunspot:solr:start
		~/bin/rake db:seed
		~/bin/rake sunspot:solr:stop
	else
		~/bin/rake elasticsearch:wipe
		~/bin/rake db:migrate:clean
		~/bin/rake db:seed
		~/bin/rake db:migrate
		~/bin/rake environment elasticsearch:import:model CLASS=Ontology
	fi
	~/bin/rake generate:metadata

	# if there is no single user registered in the DB, the rake tasks below fail
	X=${ psql -A -t -U ${DBUSER} -d ${DB} \
			-c 'select COUNT(*) from users where admin=true;' ; }
	if [[ $X == '0' ]]; then
		X=${ openssl rand -hex 64 ; }
		print 'me = User.new name: "import", email: "import@localhost",' \
			"password: '$X'\nme.admin = true\n"'me.confirm!\nexit' \
			>tmp/1st_user.rb
		~/bin/rails r tmp/1st_user.rb
		Log.info 'You may register yourself within the ontohub web app and' \
			"than use   ${PROG} -A 'your user name'   to make you an ontohub" \
			'web app admin.'
	fi

	~/bin/rake import:logicgraph

	[[ -f lib/tasks/hets.rake ]] || return

	# All remaining tasks need a running hets server
	typeset X=${ pgrep -f bin/god ; }
	[[ -z $X ]] && ~/etc/god-serv.sh start	# fresh install
	Log.info 'Waiting for ontohub-god (hets-server) to come up ...'
	integer SEC=60
	while (( SEC > 0 )); do
		X=${ print 'GET / HTTP/1.1\nHost: localhost\n' |netcat localhost 8000; }
		[[ -n $X ]] && break
		(( SEC-- ))
		print -n '.'
		sleep 1
	done
	print '.'
	if [[ -z $X ]]; then
		Log.info 'Bootstrapping hets ...'
		hets-server -X >/dev/null 2>&1 &
		(( $? )) || X=$!
	fi
	if [[ -n $X ]]; then
		~/bin/rake hets:generate_first_instance
		[[ $X =~ ^[0-9]+ ]] && kill -9 $X
	else
		Log.warn 'Skipping "rake hets:generate_first_instance"'
	fi

	# and these tasks need even the running web app, too.
	X=${ ~/etc/puma-serv.sh status 2>/dev/null ; }
	[[ -z $X ]] && ~/etc/puma-serv.sh start >tmp/puma.out 2>&1 &
	Log.info 'Waiting for puma (ontohub web app) to come up ...'
	SEC=60
	while (( SEC > 0 )); do
		X=${ pgrep -f 'puma.*tcp://' ; }
		[[ -n $X ]] && break
		(( SEC-- ))
		print -n '.'
		sleep 1
	done
	print '.'
	if [[ -n $X ]]; then
		~/bin/rake generate:categories
		~/bin/rake generate:proof_statuses
	else
		Log.warn 'Skipping "rake generate:{proof_statuses,categories}"'
	fi
}

function dba {
	typeset DB='ontohub' DBUSER='ontohub'
	[[ -n ${CFG[renv]} && ${CFG[renv]} != 'production' ]] && DB+='_development'

	if [[ -n ${CFG[admin]} ]]; then
		CMD="UPDATE users SET admin=true where name='${CFG[admin]}';"
	elif [[ -n ${CFG[ulist]} ]]; then
		CMD='SELECT id,email,name,admin FROM users;'
	fi
	[[ -n ${CMD} ]] && psql -U ${DBUSER} -d ${DB} -c "${CMD}"
}

function doMain {
	if ! pathchk -p "${CFG[dest]}"; then
		Log.fatal "path check of '${CFG[dest]}' failed."
		return 1
	fi
	if [[ ${CFG[dest]} != ${CFG[repo]} ]]; then
		if ! pathchk -p "${CFG[repo]}" ; then
			Log.fatal 'path check of '${CFG[repo]}' failed.'
			return 2
		fi
	fi

	# just a _simple_ check - developers w/o 64bit should not develop ;-)
	typeset LIB='/usr/lib/x86_64-linux-gnu/libQtWebKit.so'
	if [[ ! -e ${LIB} ]] && \
		[[ -n ${CFG[renv]} && ${CFG[renv]} != 'production' ]]
	then
		Log.info 'Missing QtWebKit - switching to production mode.'
		CFG[renv]='production'
	fi

	[[ -z ${GIT} ]] && Log.fatal "'git' not found - exiting." && return 3

	updateRepo || { Log.fatal 'Update failed.' ; return 4 ; }
	[[ -n ${CFG[update]} ]] && return 0

	grep -q _solr Gemfile && HAS_SOLR=1

	if ! buildGems ; then
		Log.fatal 'Building gems failed.'
		return 5
	fi

	[[ -n ${CFG[reset]} ]] && resetDb
	# restart the workers aka webApp 
	[[ -e /tmp/pumactl.sock ]] && ~/etc/puma-serv.sh restart
}

[[ -n ${BRANCH} ]] && CFG[branch]="${BRANCH}"
Man.addFunc MAIN '' '[+NAME?'"$PROG"' - setup or update the ontohub application environment.]
[+DESCRIPTION?The script clones the Ontohub Application Repository (OAR) \b'"${CFG[url]}"'\b if not already done, switches to the desired branch (if given), pulls in all changes from its origin and builds the corresponding ruby application environment (RAE) aka ruby gems.]
[h:help?Print this help and exit.]
[F:functions?Print out a list of all defined functions. Just invokes the \btypeset +f\b builtin.]
[H:usage]:[function?Show the usage information for the given function if available and exit. See also option \b-F\b.]
[T:trace]:[fname_list?A comma or whitspace separated list of function names, which should be traced during execution.]
[+?]
[A:admin]:[user?Just add \badmin\b rights for the named onthub application \auser\a and exit.]
[b:branch]:[name?The name of the branch to switch to/checkout before doing anything. Default: \b$BRANCH\b if set, otherwise use as is.]
[C:nocommit?When the repository gets cloned, patches (if available) get applied and on success the changes commited to the local repository. Using this option prevents commiting the changes.]
[D:datadir]:[dir?The base directory where the application/git gets redirected to store its data. Since the application has no appropriate setting but uses always $PassengerAppRoot/data/* alias ~ontohub/ontohub/data/* for git data, \bdata\b gets symlinked to the given \adir\a if it actually exists. Default: '"${CFG[datadir]}"']
[d:destbase]:[dir?The directory where the gems \bbundler\b should store the application gems. The bundler creates a \bruby\b/\aVERSION\a sub directory beneath it, where it will store all the libs, docs and utilities. Default: '"${CFG[dest]}"']
[e:env?The rails environment to use. Default is \bproduction\b.]
[L:list?Get a summary of registered ontohub users.]
[R:reset?Reset and seed the database after the a successful deployment of the web application.]
[r:repobase]:[dir?The directory which contains/will contain the OAR clone \bontohub\b. Default: '"${CFG[repo]}"']
[u:update?Just clone/update the repository but do not build the gems.]
[+NOTES?Just in case: If deployed in "production" mode \bconfig/environments/production.rb\b will be used, otherwise \bdevelopment.rb\b or \btest.rb\b. To run rails without Apache httpd in front of it in production mode (i.e. cd ~ontohub/ontohub; rails server), one needs to set \bconfig.serve_static_assets = true\b in \bproduction.rb\b to avoid ActionController::RoutingErrors for static content.]
'
X="${ print ${Man.FUNC[MAIN]} ; }"
CFG[commit]=1
integer DBA=0
while getopts "${X}" option ; do
	case "$option" in
		h) showUsage ${PROG} MAIN ; exit 0 ;;
		F) typeset +f ; exit 0 ;;
		H)  if [[ ${OPTARG%_t} != $OPTARG ]]; then
				$OPTARG --man   # self-defined types
			else
				showUsage "$OPTARG" "$OPTARG"   # function
			fi
			exit 0
			;;
		T) [[ ${OPTARG} == 'ALL' ]] && typeset -ft ${ typeset +f ; } || \
			typeset -ft ${OPTARG//,/ } ;;
		A) CFG[admin]="${OPTARG}"; DBA=1 ;;
		b) CFG[branch]="${OPTARG// /_}" ;;
		C) CFG[commit]=0 ;;
		D) [[ -d ${OPTARG} ]] && CFG[datadir]="${OPTARG}" || \
			Log.warn "Git data dir '${OPTARG}' doesn't exist - ignored." ;;
		d) CFG[dest]="${OPTARG}" ;;
		e) CFG[renv]="${OPTARG}" ;;
		L) CFG[ulist]=1 ; DBA=1 ;;
		r) CFG[repo]="${OPTARG%%/}/ontohub" ;;
		R) CFG[reset]=1 ;;
		u) CFG[update]=1 ;;
	esac
done
X=$((OPTIND-1))
shift $X && OPTIND=1

if (( DBA )); then
	dba
else
	doMain "$@" 
fi
(( $? )) || Log.info 'Done.'
