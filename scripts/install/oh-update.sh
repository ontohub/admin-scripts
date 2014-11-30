#!/bin/ksh93

unset CFG LC_ALL LANG LANGUAGE
typeset -A CFG
export LC_CTYPE=C LC_MESSAGES=C LC_COLLATE=C LC_TIME=C GIT=${ whence git ; }

CFG[url]='https://github.com/ontohub/ontohub'
CFG[repo]=${HOME%%/}/ontohub CFG[dest]=${HOME%%/}

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

function updateRepo {
	typeset OUT=''
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
	return 0
}

function buildGems {
	typeset X Y A RUBY=${ whence ruby ; }

	[[ -z ${RUBY} ]] && Log.fatal "No 'ruby' installed?" && return 1
	cd "${CFG[repo]}" || return 4

	# At least on Ubuntu amd64 ruby whines about unspecific versions like 2.1
	X=$(<.ruby-version)
	Y=${ normalizeRubyVersion .ruby-version ; }
	[[ -n $X && $X != $Y ]] && \
		Log.warn "Changing incorrect .ruby-version '$X' to '$Y'!" && \
		print "$Y" >.ruby-version

	A=( ${ ${RUBY} -e 'puts RUBY_VERSION' 2>/dev/null ; } )
	if [[ -z $A ]]; then
		cd /		# need the sys defaults
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
	sed -e "/group: / s,:.*,: 'ontohub'," -i config/settings/production.yml
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
}

function resetDb {
	cd "${CFG[repo]}" || return 4

	Log.info 'Resetting database ...'

	[[ -n ${CFG[prod]} ]] && RAILS_ENV='production' || RAILS_ENV='development'
	export RAILS_ENV

	~/bin/rake db:migrate:reset
	~/bin/rake sunspot:solr:start
	~/bin/rake db:seed
	~/bin/rake sunspot:solr:stop

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
[d:destbase]:[dir?The directory where the gems \bbundler\b should store the application gems. The bundler creates a \bruby\b/\aVERSION\a sub directory beneath it, where it will store all the libs, docs and utilities. Default: '"${CFG[dest]}"']
[P:production?Build the production environment, i.e. do not include development or test related modules. Usually used on servers to reduce runtime dependencies and space consumption.]
[R:reset?Reset and seed the database after the a successful deployment of the web application.]
[r:repobase]:[dir?The directory which contains/will contain the OAR clone \bontohub\b. Default: '"${CFG[repo]}"']
[u:update?Just clone/update the repository but do not build the gems.]
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
