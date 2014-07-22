#!/bin/bash

# |----------------|
# | How this works |
# |----------------|

# You can run this script with -f to force update.
# If you run it with environment variable MODERN_TALKING to 1,
# it will produce verbose messages describing what the script is doing.
# EXAMPLE: MODERN_TALKING=1 ./update_ontohub.sh -f

# needed to load the rvm-function in order to use it later
source /usr/local/rvm/scripts/rvm

# |-----------------------------------------|
# | Avoid this script runnig simultaneously |
# |-----------------------------------------|
SCRIPTNAME=`basename "$0"`
LOCK="/tmp/${SCRIPTNAME}.lock"
exec 8>$LOCK

if ! flock --nonblock 8; then
  if [[ "$MODERN_TALKING" == "1" ]]; then echo "$SCRIPTNAME already running"; fi
  exit 1
fi

# |---------------|
# | The main part |
# |---------------|

# do git stuff #
################
deploy_path=/srv/http/ontohub
branch=`cat $deploy_path/BRANCH`

# mailing stuff #
#################
TARGET_EMAIL_ADDRESS="ontohub-dev-l@ovgu.de"
GIT_ERROR_SUBJECT="An error with git occourd on $branch"
DEPLOY_ERROR_SUBJECT="deploy error on $branch"
DEPLOY_ERROR_FIXED="The error which prevents deploy is fixed"
MESSAGE=/tmp/backlog

# these are errors which not should trigger mail sending
# to add a new message add '\|string' (whithout ticks)
# to the string beneath
########################################################
EXCLUDED_GIT_ERRORS="unable to connect to github.com"


## update the local mirror
GIT_DIR=$deploy_path/repo git remote update >& /tmp/backlog
if [[ "$?" != "0" ]] ; then
  if grep -q -w "$EXCLUDED_GIT_ERRORS" "$MESSAGE"; then
   exit 1
  fi
    /usr/bin/mail -s "$GIT_ERROR_SUBJECT" "$TARGET_EMAIL_ADDRESS" < $MESSAGE
else
  if [[ "$MODERN_TALKING" == "1" ]]; then echo 'remote update successful'; fi
fi
rm /tmp/backlog

## fetch revisions
old_rev=`cat $deploy_path/current/REVISION || echo -n`
current_rev=`GIT_DIR=$deploy_path/repo git rev-parse --short $branch`


## compare revisions
if [ "$old_rev" = "$current_rev" ]; then
  if [[ "$MODERN_TALKING" == "1" ]]; then echo 'versions are equal'; fi
  [ "$1" = "-f" ] || exit 0
else
  if [[ "$MODERN_TALKING" == "1" ]]; then echo 'versions are not equal'; fi
fi


# install the bundle with deployment #
######################################

## checkout version-relevant files into a temporary working copy
## and then bundle install into the shared bundle directory.

rm -rf /tmp/bundle-worker
mkdir -p /tmp/bundle-worker

cd $deploy_path/repo
git show "$branch:Gemfile" > /tmp/bundle-worker/Gemfile
git show "$branch:Gemfile.lock" > /tmp/bundle-worker/Gemfile.lock
git show "$branch:.ruby-version" > /tmp/bundle-worker/.ruby-version

cd /tmp/bundle-worker



if [[ "$MODERN_TALKING" == "1" ]]; then echo 'trying to bundle install'; fi

rvm default do bundle --path $deploy_path/shared/bundle --deployment --without development test >& /tmp/backlog
if [[ "$?" != "0" ]]; then
  if [[! -e "$deploy_path/current/FAILED_REVISION" ]]; then
    /usr/bin/mail -s "$DEPLOY_ERROR_SUBJECT" "$TARGET_EMAIL_ADDRESS" < $MESSAGE
  fi
  rm /tmp/backlog
  if [[ "$MODERN_TALKING" == "1" ]]; then echo 'bundle install not successful'; fi
  echo $current_rev > $deploy_path/current/FAILED_REVISION
  exit 1
else
  if [[ -e "$deploy_path/current/FAILED_REVISION" ]]; then
    rm $deploy_path/current/FAILED_REVISION
    echo $DEPLOY_ERROR_FIXED | /usr/bin/mail -s "$DEPLOY_ERROR_SUBJECT" "$TARGET_EMAIL_ADDRESS"
  fi
  if [[ "$MODERN_TALKING" == "1" ]]; then echo 'bundle install successful'; fi
fi


# deploy now #
##############

## change to current path
cd $deploy_path/current

## enforce other settings for bundler, necessary to find capistrano
bundle config --local disable_shared_gems 0 > /dev/null
bundle config --local without "development:test" > /dev/null

if [[ "$MODERN_TALKING" == "1" ]]; then echo 'trying to deploy'; fi
rvm default do bundle exec cap production deploy >& /tmp/backlog
if [[ "$?" != "0" ]]; then
  if [[! -e "$deploy_path/current/FAILED_REVISION" ]]; then
    /usr/bin/mail -s "$DEPLOY_ERROR_SUBJECT" "$TARGET_EMAIL_ADDRESS" < $MESSAGE
  fi
  rm /tmp/backlog
  echo $current_rev > $deploy_path/current/FAILED_REVISION
  exit 1
  if [[ "$MODERN_TALKING" == "1" ]]; then echo 'deploy not successful'; fi
else
  if [[ -e "$deploy_path/current/FAILED_REVISION" ]]; then
    rm $deploy_path/current/FAILED_REVISION
    echo $DEPLOY_ERROR_FIXED | /usr/bin/mail -s "$DEPLOY_ERROR_SUBJECT" "$TARGET_EMAIL_ADDRESS"
  fi
  if [[ "$MODERN_TALKING" == "1" ]]; then echo 'deploy successful'; fi
  echo $current_rev > $deploy_path/current/REVISION
fi
