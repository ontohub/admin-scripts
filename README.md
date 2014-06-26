Admin-Scripts
============

In these Repository are the script which are on the ontohub server
for the admins. The scripts should make developing and maintaining
of ontohub instances more comfortable.

## ontohub-console.sh
This script open from the rails console

## update_ontohub.sh

This script is for better developing. Using Cron
this script automatically updates the production
system if necessery.

If it called normally it only generating output if
an error occourrd.
To change this behaviour it could started with the enviorment
variable ```MODERN_TALKING``` on value ```1```.

The ```-f``` option can be used for forcing an update

How to call it this way you see in the Example below:

```bash
MODERN_TALKING=1 ./update_ontohub.sh -f
```
