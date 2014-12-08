#!/bin/ksh93

unset CFG LC_ALL LANG LANGUAGE

MY_ORG="© 2012-${ date +%Y ; } Universität Magdeburg and Universität Bremen"
MY_NAME='Ontohub'

typeset -A CFG
export LC_CTYPE=C LC_MESSAGES=C LC_COLLATE=C LC_TIME=C GIT=${ whence git ; }
integer HAS_SOLR=0

CFG[url]='https://github.com/ontohub/ontohub.git'
CFG[repo]=${HOME%%/}/ontohub CFG[dest]=${HOME%%/}
CFG[datadir]=/data/git

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
		PULL=0
	fi

	[[ ! -d ${CFG[repo]}/.git/refs ]] && Log.fatal "'${CFG[repo]}' exists" \
		'but it does not seem to be a git repository.' && return 3
	cd "${CFG[repo]}" || return 4

	if [[ -f .git/HEAD ]]; then
		OUT=$(<.git/HEAD)
		[[ ${OUT} =~ "/" ]] && OUT="${OUT##*/}" || OUT=''
	fi

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

	if (( ! PULL )); then
		# base config for the first time
		typeset A B X HNAME
		integer I
		A=( ${ getent hosts ${ hostname ; } ; } )
		for (( I=1 ; I < ${#A[@]}; I++ )); do
			B=( ${A[I]//./ } )
			(( ${#B[@]} > 1 )) && HNAME="${A[I]}" && break
		done
		if [[ -n ${HNAME} ]]; then
			if [[ ${CFG[branch]} == 'staging' ]]; then
				MY_NAME+=' β'
			elif [[ ${CFG[branch]} != 'master' ]]; then
				MY_NAME+=' Γ'
			fi
			X='@'
			[[ ${BRANCH} != 'production' && ${HNAME#*.} == 'ontohub.org' ]] && \
				HNAME="${HNAME%%.*}.iws.cs.ovgu.de" && X="+oh-${HNAME%%$.*}@"
			Y=${HNAME#*.}
			sed -e "/^hostname:/ s,:.*,: ${HNAME}," \
				-e "/^email:/ s,:.*,: noreply${X}${Y}," \
				-e "/^fallback_commit_email:/ s,:.*,: ontohub_system${X}${Y}," \
				-e "s,about.example.com,${HNAME}/about/," \
				-e "s,exceptions@example.com,ontohub${X}${Y}," \
				-e "s,exception-recipient@example.com,ex${X}${Y}," \
				-e "s,ontohub exception,ontohub ex," \
				-e "/^name:/ s,:.*,: '${MY_NAME}'," \
				-e "/text: Foo Institute/ s,:.*,: ${MY_ORG}," \
				-i config/settings.yml
		fi

		# for cookie encryption
		F=~ontohub/ontohub/config/initializers/secret_token.rb
		X=' bootstrap.log: lastlog: auth.log: dmesg'
		#X=${ ~ontohub/bin/rake secret ; }  # avoid cyclic ruby dependency
		X=${ openssl rand -hex -rand ${X// /\/var/\/log\/} 64 ; }
		[[ -n $X ]] && print "Ontohub::Application.config.secret_token = '$X'" \
			>$F

		# we have the redirect rules included within the vhosts's httpd config
		rm -f public/.htaccess

		sed -e '/.development-state/ a\      display: none' \
			-i app/assets/stylesheets/navbar.css.sass
	fi

	# "no git.datadir setting" workaround
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

	# passenger wanna write its {production|development|sidekiq}.log  here
	# but the build and whatever else as well  =8-(
	[[ -e log ]] || { mkdir log || return 14 ; }
	[[ ${BRANCH} == 'production' || ${BRANCH} == 'staging' ]] && \
		X='production' || X='development'
	touch log/${X}.log
	# god.log comes from the god-serv service (is relocatable)
	[[ ! -e ~/log ]] && mkdir ~/log
	chmod g+w data log log/${X}.log ~/log

	# don't call dangerous scripts, which may destroy data unintentionally, or
	# invoke sudo behind the scene, or seem to be simply overhead
	chmod 0644 script/{install-on-ubuntu,backup,rails} 2>/dev/null

	return 0
}

function buildGems {
	typeset X Y A RUBY=${ whence ruby ; }

	[[ -z ${RUBY} ]] && Log.fatal "No 'ruby' installed?" && return 1
	cd "${CFG[repo]}" || return 4

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

	[[ -n ${CFG[prod]} ]] && RAILS_ENV='production' || RAILS_ENV='development'
	export RAILS_ENV

	[[ ${RAILS_ENV} == 'production' ]] && X='vendor/bundle' || X='../ruby'
	if [[ -f ${CFG[dest]}/VERSION && -d $X ]]; then
		A=( $(<${CFG[dest]}/VERSION) )
		if [[ $A == "${CFG[head]}@${CFG[rvers]}@${CFG[gvers]}@${CFG[bvers]}" ]]
		then
			Log.info 'Gems are already up to date. Nothing to do.'
			return 0
		fi
	fi

	# Preconfigure - who knows, why ...
	# git stash ; git stash apply
	sed -e "/group: / s,:.*,: 'webservd'," -i config/settings/production.yml
	sed -e 's,username:.*,username: ontohub,' -i config/database.yml

	Log.info 'Trying to build ontohub gems ...'
	# discard any settings from previous runs (especially BUNDLE_WITHOUT:)
	rm -f .bundle/config

	# 1693M
	if [[ ${RAILS_ENV} == 'production' ]]; then
		A=( '--deployment'
			'--without' 'development' 'test' #'deployment'
		)
		# don't show error details on web pages
		sed -e '/config.consider_all_requests_local/ s,true,false,' \
			-i config/environments/production.rb
	else
		unset A
		# show error details on web pages
		sed -e '/config.consider_all_requests_local/ s,false,true,' \
			-i config/environments/production.rb
	fi
	integer JOBS=1
	[[ ${ uname -s ; } == 'SunOS' ]] && JOBS=${ psrinfo | wc -l ; } || \
		JOBS=${ grep ^processor /proc/cpuinfo | wc -l ; }
	(( JOBS > 1 )) && A+=( "--jobs=${JOBS}" )

	# we do not want unmaintained libxml/libxslt
	bundle config build.nokogiri --use-system-libraries
	
	# update the Gemfile.lock file and actually build the gems
	bundler install --path="${CFG[dest]}" "${A[@]}" || return $?

	# for convinience put the tools into a std path
	[[ -d ~/bin ]] || mkdir ~/bin
	[[ -d ~/bin ]] && bundler install --binstubs ~/bin

	X=${ umask ; }
	umask 022	# allow webservd to update e.g. tmp/cache/*
	# NOTE: W/o having RAILS_ENV set, it assumes RAILS_ENV=production ...
	~/bin/rake assets:precompile

	# recommended by builder doc - no clue, whether it makes a diff
	[[ -d shared ]] || mkdir shared
	ln -sf ../vendor/bundle shared/vendor_bundle

	# tell possibly running passengers to restart
	[[ -d tmp ]] || mkdir tmp
	touch tmp/restart.txt

	# stamp this build
	print "${CFG[head]}@${CFG[rvers]}@${CFG[gvers]}@${CFG[bvers]}" \
		>${CFG[dest]}/VERSION
	umask $X
}

function resetDb {
	cd "${CFG[repo]}" || return 4

	Log.info 'Resetting database ...'

	[[ -n ${CFG[prod]} ]] && RAILS_ENV='production' || RAILS_ENV='development'
	export RAILS_ENV

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
	fi

	touch tmp/restart.txt
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

	[[ -z ${CFG[reset]} ]] && return 0 || resetDb
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
