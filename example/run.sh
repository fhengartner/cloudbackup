#!/bin/bash

# "tar" needs UTF-8 charset
export LANG="de_CH.UTF-8"

# run
../backup.sh conf/backup.conf -v
