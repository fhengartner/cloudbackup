#!/bin/bash
#
# Dropbox Uploader
#
# Copyright (C) 2015 Florian Hengartner <fhengartner@gmail.com>
#
########################################################################

# fail on undefined variables
set -o nounset
# exit the script if any statement returns a non-true return value
set -o errexit
# fail on pipe error
set -o pipefail
# disable globbing
set -o noglob

# default values
DEBUG=1

# dont edit these
DEPENDENCIES="gpg mysqldump basename"
VERSION="0.1"
NOW=$(date +"%Y-%m-%d")

###################
# UTILITIES
###################

error() {
	echo -e "ERROR: $*"
	exit 1
}

ensure_folder_exists() {
	local NAME=$1
	local DIR=$2
		
	[[ ! -d "$DIR" ]] && echo "ERROR: Directory ($NAME) does not exist: $DIR" && return 1
	
	return 0
}

ensure_file_exists() {
	local NAME=$1
	local FILE=$2
	
	[[ ! -f "$FILE" ]] && echo "ERROR: File ($NAME) does not exist: $FILE" && exit 1
	
	return 0
}


check_dependencies() {
	local NOT_FOUND=""
	for i in $DEPENDENCIES; do
	    type -p "$i" > /dev/null || NOT_FOUND="$NOT_FOUND $i"
	done
	
	[[ -z $NOT_FOUND ]] && return 0
	
	error "Required program(s) could not be found: $NOT_FOUND"
}

verify() {
	if [[ $DEBUG != 0 ]]; then
	    echo "VERSION: $VERSION"
	    uname -a 2> /dev/null && true
	fi

	check_dependencies
	
	[[ ! -f "$ENCRYPT_PASSPHRASE_FILE" ]] && error "Unable to find encryption file ($ENCRYPT_PASSPHRASE_FILE)"
	
	ensure_folder_exists "BACKUP_FOLDER" "$BACKUP_FOLDER" || exit 1

	ensure_folder_exists "LOG_FOLDER" "$LOG_FOLDER" || exit 1

	ensure_file_exists "CONFIG_FILE_DROPBOX_UPLOADER" "$CONFIG_FILE_DROPBOX_UPLOADER"

	ensure_file_exists "CONFIG_FILE_FOLDERS" "$CONFIG_FILE_FOLDERS"

	ensure_file_exists "CONFIG_FILE_DBS" "$CONFIG_FILE_DBS"
}

usage() { echo -e "Usage: $0 <configfile> [-q|-v|-n] " 1>&2; exit 1; }

parse_arguments() {
	while getopts "qvn" o; do
	    case "${o}" in
	        q) DEBUG=0;;
	        v) DEBUG=1;;
			n) SKIP_UPLOAD=1;;
	        *)
	            usage
	            ;;
	    esac
	done
	shift $((OPTIND-1))
}

########################
# BACKUP LOGIC
########################

compress() {
	gzip
}

encrypt() {
	gpg --batch --no-use-agent --no-tty --trust-model always \
		--symmetric --passphrase-file $ENCRYPT_PASSPHRASE_FILE
}

# upload file to dropbox
upload() {
	local LOCAL_PATH="$*"
	local REMOTE_FILE=$(basename $LOCAL_PATH)
	
	[[ ! -f "$LOCAL_PATH" ]] && echo -e "ERROR: LOCAL_PATH does not exist: $LOCAL_PATH" && return 1
	[[ -z $REMOTE_FILE ]] && echo -e "ERROR: REMOTE_FILE is empty LOCAL_PATH=$LOCAL_PATH" && return 1
	
	local REMOTE_PATH="/backup/$NOW/$REMOTE_FILE"
		
	local DROPBOX_UPLOADER="./vendor/dropboxuploader/dropbox_uploader.sh -q -f $CONFIG_FILE_DROPBOX_UPLOADER "
	
	[[ $DEBUG != 0 ]] && echo "] upload to dropbox: $LOCAL_PATH $REMOTE_PATH"
	
	[[ $SKIP_UPLOAD == 1 ]] && return 0

	$DROPBOX_UPLOADER upload $LOCAL_PATH $REMOTE_PATH
}

build_file_path() {
	local NAME=$1
	local EXTENSION=$2
	
	[[ -z "$NAME" ]] && echo "ERROR: build_file_path(): no argument given." && return 1
	[[ -z "$EXTENSION" ]] && echo "ERROR: build_file_path(): parameter EXTENSION is empty." && return 1
	
	local OUTPUT_FILE=${NAME}_${NOW}.$EXTENSION
	
	echo ${BACKUP_FOLDER}$OUTPUT_FILE
	
	return 0
}

backup_folder() {
	local SOURCE_FOLDER=$1
	local NAME=$2
	
	ensure_folder_exists "SOURCE_FOLDER" $SOURCE_FOLDER || return 1

	[[ $DEBUG != 0 ]] && echo "] folder: $SOURCE_FOLDER"

	local OUTPUT_FILE_PATH=$(build_file_path ${NAME} "tar.gz.gpg")
	
	# TODO: exclude path's from tar
	tar c "$SOURCE_FOLDER" | compress | encrypt > "$OUTPUT_FILE_PATH"
	
	upload "$OUTPUT_FILE_PATH"	
}

# backup folders listed in config-file
backup_folders() {
	while read -r DIR NAME; do
		[[ -z $DIR ]]  && continue # skip empty lines
		[[ -z $NAME ]]  && NAME=$(basename $DIR)
		[[ -z $NAME ]]  && continue # TODO log error
	
		backup_folder "$DIR" "$NAME"
		
	done < ${CONFIG_FILE_FOLDERS}
}

# fake mysqldump
mysqldump() {
	echo "I AM THE DUMP"
}

# send email for mysqldump error
send_notification() {
	local DBNAME=$1
	local LOG=$2
	
	if [[ -z $NOTIFICATION_EMAIL_ADDRESS ]]; then
		[[ $DEBUG != 0 ]] && echo "WARN: NOTIFICATION_EMAIL_ADDRESS is not set. no email sent."
		return 0
	fi
	
	[[ ! -f "$LOG" ]] && echo "WARN: logfile $LOG does not exist. no email sent" && return 0
	
	cat "$LOG" | mailx -s "Backup-Error: Database $DBNAME" "$NOTIFICATION_EMAIL_ADDRESS"
}

has_mysql_error() {
	# -s => true if file is not empty
	[[ -f "$*" ]] && [[ ! -s "$*" ]]	
}

# backup mysql database
backup_database() {
	local DBNAME=$1
	local USER=$2
	local PW=$3
	local HOST=$4
	local LOG=${LOG_FOLDER}/db_${DBNAME}.log
	
	[[ $DEBUG != 0 ]] && echo "] database: HOST=$HOST DB=$DBNAME USER=$USER"
	
	# has_mysql_error is only reliable if the old logfile is removed 
	rm -f $LOG
	
	local OUTPUT_FILE_PATH=$(build_file_path ${DBNAME} "sql.gz.gpg")
	
	mysqldump -u $USER --password=$PW -h $HOST --log-error=$LOG $DBNAME | compress | encrypt > $OUTPUT_FILE_PATH
	
	has_mysql_error $LOG && send_notification $DBNAME $LOG

	upload "$OUTPUT_FILE_PATH"
	
	return 0
}

# backup databases listed in config-file
backup_databases() {
	i=0
	while read -r DBNAME USER PW HOST; do
		[[ -z $DBNAME ]]  && continue # skip empty lines
		[[ -z $USER ]]  && echo -e "WARN: user is empty! ignoring line ${i} of $CONFIG_FILE_DBS" && continue
		[[ -z $HOST ]]  && HOST=localhost

		backup_database "$DBNAME" "$USER" "$PW" "$HOST"
		let ++i
	done < ${CONFIG_FILE_DBS}
}

########################
# MAIN
########################

# first argument is path to configfile
CONFIGFILE=${1:-""}
if ! [ -e "$CONFIGFILE" ]; then
    usage
fi

if ! [ -f "$CONFIGFILE" ]; then
    error "Path to config-file is invalid."
fi

source $CONFIGFILE

# config values
SKIP_UPLOAD=${SKIP_UPLOAD:-0}
BACKUP_FOLDER=${BACKUP_FOLDER:-/tmp/backup/}
LOG_FOLDER=${LOG_FOLDER:-${BACKUP_FOLDER}/log/}
ENCRYPT_PASSPHRASE_FILE=${ENCRYPT_PASSPHRASE_FILE:-}
CONFIG_FILE_FOLDERS=${CONFIG_FILE_FOLDERS:-folders.conf}
CONFIG_FILE_DBS=${CONFIG_FILE_DBS:-dbs.conf}
CONFIG_FILE_DROPBOX_UPLOADER=${CONFIG_FILE_DROPBOX_UPLOADER:-~/.dropbox_uploader)}
NOTIFICATION_EMAIL_ADDRESS=${NOTIFICATION_EMAIL_ADDRESS:-}

shift
parse_arguments $@

verify

backup_databases
backup_folders

# TODO: cleanup old files
