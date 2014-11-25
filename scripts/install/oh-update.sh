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

function updateRepo {
	typeset OUT
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

	if [[ -n ${CFG[branch]} ]]; then
		${GIT} checkout ${CFG[branch]} || return 5
	fi
	if (( PULL )); then
		Log.info "Fetching '${CFG[repo]##*/}' ..."
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
	typeset X A RUBY=${ whence ruby ; }

	[[ -z ${RUBY} ]] && Log.fatal "No 'ruby' installed?" && return 1
	cd "${CFG[repo]}" || return 4

	# we always use the systems default ruby version to avoid surprises when
	# running services ...
	cd /		# need the sys defaults
	A=( ${ ${RUBY} -e 'puts RUBY_VERSION' 2>/dev/null ; } )
	[[ -z $A ]] && \
		Log.warn 'Unable to determine instaĺled ruby version.' && return 1
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
	cd -

	[[ -z ${CFG[prod]} ]] && X='vendor/bundle' || X='../ruby'
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

	Log.info 'Trying to build ontohub gems ...'
	print "${CFG[rvers]}" >.ruby-version
	[[ -z ${CFG[prod]} ]] && unset A || \
		A=( '--deployment' '--without' 'development' 'test' )
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

	[[ -z ${GIT} ]] && Log.fatal "'git' not found - exiting." && return 3

	updateRepo || { Log.fatal 'Update failed.' ; return 4 ; }

	if ! buildGems ; then
		Log.fatal 'Building gems failed.'
		return 5
	fi
}

Man.addFunc MAIN '' '[+NAME?'"$PROG"' - setup or update the ontohub application environment.]
[+DESCRIPTION?The script clones the Ontohub Application Repository (OAR) \b'"${CFG[url]}"'\b if not already done, switches to the desired branch (if given), pulls in all changes from its origin and builds the corresponding ruby application environment (RAE) aka ruby gems.]
[h:help?Print this help and exit.]
[F:functions?Print out a list of all defined functions. Just invokes the \btypeset +f\b builtin.]
[H:usage]:[function?Show the usage information for the given function if available and exit. See also option \b-F\b.]
[T:trace]:[fname_list?A comma or whitspace separated list of function names, which should be traced during execution.]
[+?]
[b:branch]:[name?The name of the branch to switch to/checkout before doing anything. Default: use as is.]
[d:destbase]:[dir?The directory where the gems \bbundler\b should store the application gems. The bundler creates a \bruby\b/\aVERSION\a sub directory beneath it, where it will store all the libs, docs and utilities. Default: '"${CFG[dest]}"']
[P:production?Build the production environment, i.e. do not include development or test related modules. Usually used on servers to reduce runtime dependencies and space consumption.]
[r:repobase]:[dir?The directory which contains/will contain the OAR clone \bontohub\b. Default: '"${CFG[repo]}"']
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
	esac
done
X=$((OPTIND-1))
shift $X && OPTIND=1

doMain "$@"
