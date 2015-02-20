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

LIC='[-?$Id$ ]
[-copyright?Copyright (c) 2014 Jens Elkner. All rights reserved.]
[-license?CDDL 1.0]'
typeset -r SDIR=${.sh.file%/*} FPROG=${.sh.file} PROG=${FPROG##*/}

for H in log.kshlib man.kshlib ; do
	X=${SDIR}/$H
	[[ -r $X ]] && . $X && continue
	X=${ whence $H; }
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
	[[ ${CFG[prod]} == '1' || ${OUT} =~ ^(master|staging)(\.ontohub\.org)?$ ]] \
		&& CFG[renv]='production' || CFG[renv]='development'

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

	if [[ ! -e config/settings.local.yml ]]; then
		Log.info 'Applying 1st time aka only once modifications ...'

		# base config for the first time, only.
		typeset A B HNAME SET
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
			git status -s | while read A B Y ; do
				[[ $A == '??' && -f $B ]] && SET+="$B "
			done
			[[ -n ${SET} ]] && git add ${SET}
			A=${ git commit -a -m "${X##*/}" 2>&1 ; }
			(( $? )) && print "$A" || print "Patch ${X##*/} applied"
		done
		if [[ -e public/.htaccess ]]; then
			# missing 1170-frontend-notes.patch
			rm -f public/.htaccess
		fi
		# oh my goodness, this stuff is whitespace sensitive!
		sed -e '/\.development-state/ { p; s,\.dev.*,  display: none, }' \
			-i app/assets/stylesheets/navbar.css.sass

		# missing 1170-puma-support.patch ?
		grep -q puma Gemfile || sed -e "/^source / a\gem 'puma'" -i Gemfile
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

			if ! grep -q config.fqdn config/application.rb ; then
				# mail setting in config/settings.yml seems to be useless
				X='\
	config.action_mailer.default_url_options = { :host => '"'${HNAME}'"' }\
	config.action_mailer.delivery_method = :smtp\
	config.action_mailer.smtp_settings = {\
		:address				=> "'"${MAIL_GW:-mail}"'",\
		:port					=> 25,\
		:enable_starttls_auto	=> false,\
		:domain					=> '"'${HNAME}'"'\
	}'
				sed -e "/= APP_CONFIG =/ a\  ${X}" \
					-e '/# ActionMailer/,/end/ { N;d }' -i config/application.rb
				# Grrr. All the config stuff is a real big crazy mess.
				sed -e '/config.action_mailer.default_url_options/ s,c,#c,' \
					-i config/environments/development.rb
			fi
		fi

		# cookie encryption: overwrite config/initializers/secret_token.rb
		#X=${ ~ontohub/bin/rake secret ; }  # no way - cyclic ruby dependency
		X=' bootstrap.log: lastlog: auth.log: dmesg'
		X=${ openssl rand -hex -rand ${X// /\/var/\/log\/} 64 ; }
		[[ -n $X ]] && SET+="\n\nsecret_token: $X"
	

		if ! grep -q postgresql.conf config/database.yml; then
			# missing common-settings-behavior.patch
			sed -i -e \
			'/\&config/ a\  # the directory containing the postgres DB socket\
  # see /etc/postgresql/${version}/main/postgresql.conf:unix_socket_directories\
  host: /var/run/postgresql' config/database.yml
			sed -i -e 's,username:.*,username: ontohub,' config/database.yml
		fi
		# correct/skip unused pathes
		SET+='\n
hets_path: !str /usr/bin/hets-server
hets_lib: !str /usr/lib/hets-server/hets-lib
hets_owl_tools: !str /usr/lib/hets-server/hets-owl-tools'
		if ! grep -q 'environment_light' lib/tasks/hets.rake ; then
			# missing 1170-hets-binary-path.patch
			sed -e '/^version_minimum_version:/ h
/^hets_path:/,/^version_minimum_version:/ d
/^version_minimum_revision:/ { H; x; i\hets_path:\
  - '"${HETS_DESTDIR}"'/bin/hets-server\
hets_lib:\
  - '"${HETS_DESTDIR}"'/lib/hets-server/hets-lib\
hets_owl_tools:\
  - '"${HETS_DESTDIR}"'/lib/hets-server/hets-owl-tools\

}'			-i config/hets.yml
			sed -e '/HETS_CMD =/ s,hets ,hets-server ,' -i lib/tasks/hets.rake
			sed -i -e '/system/ s,hets ,hets-server ,' -e '/strip/ s,hets`,hets-server`,' \
			lib/tasks/test.rake
			sed -i -e '/exec/ s,hets ,hets-server ,' config/god/hets_workers.rb
		fi

		# See ~admin/etc/post-install2.sh (postGit()) - "COW"
		if ! grep -q 'cp_keys' app/models/key.rb ; then
			# missing 1170-git-data_dir.patch
			sed -e "/#{config.git_user}/ s,=.*,= '${CFG[datadir]}'," \
				-i config/initializers/paths.rb
			sed -e "/AuthorizedKeysManager/ a\    system('${CFG[datadir]}/.ssh/cp_keys')" -i app/models/key.rb
		fi

		print "${SET}" >config/settings.local.yml
	fi
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
	if [[ ! -e config/puma.rb ]]; then
		# missing 1170-puma-support.patch
		Log.info 'Creating config/puma.rb ...'
		X='# see http://www.rubydoc.info/gems/puma/\n'
		X+="environment 'production'\nquiet\n"	# no need to "debug" puma
		X+="threads ${MINTHREADS},${THREADS}\nworkers ${CPUS}\n"
		X+="bind 'tcp://0.0.0.0:${WEBAPP_PORT}'\n"
		X+='preload_app!

# as suggested by the doc
on_worker_boot do
	str = @options[:control_url]
	if str then
		uri = URI.parse str
		if uri.scheme == "unix" then
			FileUtils.chmod(0770, "#{uri.path}")
		end
	end
	ActiveSupport.on_load(:active_record) do
		ActiveRecord::Base.establish_connection
	end
end
'
		print "$X" >config/puma.rb
	elif (( ! PULL )); then
		# defaults are ok - just adjust the workers
		sed -i -e "/^workers/ s,^.*,workers ${CPUS}," config/puma.rb
	fi

	if ! grep -q data_dir config/settings.yml ; then
		# missing 1170-git-data_dir.patch
		if [[ -n ${CFG[datadir]} && -d ${CFG[datadir]} ]]; then
			if [[ -d data && ! -h data ]]; then
				integer K
				for (( K=999; K > -1; K-- )); do
					[[ -d data.$K ]] || break
				done
				if (( K < 0 )); then
					Log.info "Skipping symlinking data to '${CFG[datadir]}'." \
						'Too many old backup dirs. rm data.* to cleanup.'
					return 10
				fi
				mv data data.$K || return 11
			else
				rm -f data || return 12	
			fi
			ln -s ${CFG[datadir]} data || return 13
		elif [[ ! -e data ]]; then	# do not change, if it already exists
			mkdir data || return 13
		fi
		chmod g+w data
	fi

	# the running webapp wanna write its {production|development|sidekiq}.log
	# here but the build process and whatever else as well  =8-(
	[[ -e log ]] || { mkdir log || return 14 ; }
	X=${CFG[renv]}
	touch log/${X}.log
	# god.log comes from the god-serv service (is relocatable)
	[[ ! -e ~/log ]] && mkdir ~/log
	chmod g+w log log/${X}.log ~/log

	# don't call dangerous scripts, which may destroy data unintentionally, or
	# invoke sudo behind the scene, or seem to be simply overhead
	chmod 0644 script/{install-on-ubuntu,backup,rails} 2>/dev/null

	return 0
}

function buildGems {
	typeset X Y A RUBY=${ whence ruby ; }
	integer COMMIT=0 I

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
	grep -q config.log_level config/application.rb && I=0 || I=1
	# missing 1170-log_level-misc-settings.patch
	if [[ ${RAILS_ENV} == 'production' ]]; then
		A=(
			'--without' 'development' 'test' #'deployment'
		)
		[[ -f Gemfile.lock ]] && A+=( '--deployment' )
		# don't show error details on web pages
		# and avoid the madness what gets called "Logging" in rails (actually
		# the complete actionpack/lib/action_controller/log_subscriber.rb is
		# total crap)
		(( I )) && sed -e '/config.consider_all_requests_local/ s,true,false,' \
			-e '/config.log_level/ s,^.*,	config.log_level = :warn,' \
			-i config/environments/production.rb
		# what the heck ...
		sed -e '/system / s,-v ,,' -i lib/tasks/sidekiq.rake
	else
		unset A
		# show error details on web pages
		# and use default "Logging"
		(( I )) && sed -e '/config.consider_all_requests_local/ s,false,true,' \
			-e '/config.log_level/ s,^.*,	# config.log_level = :debug,' \
			-i config/environments/production.rb
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
	(( COMMIT )) && git commit -m 'Gemfile.lock bundler update' Gemfile.lock

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
	~/bin/rake import:logicgraph
	if [[ -f lib/tasks/hets.rake ]]; then
		# Initially we have a chicken-and-egg-problem here: The ontohub-god
		# service cannot be started, before the ontohub repo is checked out and
		# prepared (done by this script). However this service is responsible for
		# running a hets instance on port 8000, which is required to be able to
		# 'rake hets:generate_first_instance'. So at least on a virign system we need
		# to bootstrap, i.e. fire it up manually ... 
		typeset X=${ pgrep -f bin/god ; }
		if [[ -n $X ]]; then
			Log.info 'Waiting for ontohub-god (hets-server) to come up ...'
			integer SEC=60
			while (( SEC > 0 )); do
				X=${ print 'GET / HTTP/1.1\nHost: localhost\n' | \
					netcat localhost 8000 ; }
				[[ -n $X ]] && break
				(( SEC-- ))
				print -n '.'
				sleep 1
			done
			print '.'
		fi
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
	fi
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
	if [[ ! -e ${LIB} ]] && [[ ${CFG[prod]} != '1' ]]; then
		Log.info 'Missing QtWebKit - switching to production mode.'
		CFG[prod]=1
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
[b:branch]:[name?The name of the branch to switch to/checkout before doing anything. Default: \b$BRANCH\b if set, otherwise use as is.]
[D:datadir]:[dir?The base directory where the application/git gets redirected to store its data. Since the application has no appropriate setting but uses always $PassengerAppRoot/data/* alias ~ontohub/ontohub/data/* for git data, \bdata\b gets symlinked to the given \adir\a if it actually exists. Default: '"${CFG[datadir]}"']
[d:destbase]:[dir?The directory where the gems \bbundler\b should store the application gems. The bundler creates a \bruby\b/\aVERSION\a sub directory beneath it, where it will store all the libs, docs and utilities. Default: '"${CFG[dest]}"']
[P:production?Build the production environment, i.e. do not include development or test related modules. Usually used on servers to reduce runtime dependencies and space consumption.]
[R:reset?Reset and seed the database after the a successful deployment of the web application.]
[r:repobase]:[dir?The directory which contains/will contain the OAR clone \bontohub\b. Default: '"${CFG[repo]}"']
[u:update?Just clone/update the repository but do not build the gems.]
[+NOTES?Just in case: If deployed in "production" mode \bconfig/environments/production.rb\b will be used, otherwise \bdevelopment.rb\b or \btest.rb\b. To run rails without Apache httpd in front of it in production mode (i.e. cd ~ontohub/ontohub; rails server), one needs to set \bconfig.serve_static_assets = true\b in \bproduction.rb\b to avoid ActionController::RoutingErrors for static content.]
'
X="${ print ${Man.FUNC[MAIN]} ; }"
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
		b) CFG[branch]="${OPTARG// /_}" ;;
		D) [[ -d ${OPTARG} ]] && CFG[datadir]="${OPTARG}" || \
			Log.warn "Git data dir '${OPTARG}' doesn't exist - ignored." ;;
		d) CFG[dest]="${OPTARG}" ;;
		P) CFG[prod]=1 ;;
		r) CFG[repo]="${OPTARG%%/}/ontohub" ;;
		R) CFG[reset]=1 ;;
		u) CFG[update]=1 ;;
	esac
done
X=$((OPTIND-1))
shift $X && OPTIND=1

doMain "$@" && Log.info 'Done.'
