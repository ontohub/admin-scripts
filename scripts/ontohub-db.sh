#!/bin/bash

if [[ "$(whoami)" != 'ontohub' ]]; then
  su postgres -c 'psql -d ontohub'
else
  psql -d ontohub
fi
