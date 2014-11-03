#!/bin/bash

if [[ "$(whoami)" != 'ontohub' ]]; then
  su - ontohub -c 'cd /srv/http/ontohub/current && bundle exec rails c production'
else
  cd /srv/http/ontohub/current && bundle exec rails c production
fi
