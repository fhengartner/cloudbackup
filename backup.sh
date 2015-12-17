#!/bin/bash

# quit script if trying to use uninitialized variables
set -o nounset
# exit the script if any statement returns a non-true return value
set -o errexit
# fail on pipe error
set -o pipefail

# default values
DEBUG=1

# dont edit these
DEPENDENCIES="gpg mysqldump basename"
VERSION="0.1"
NOW=$(date +"%Y-%m-%d")

# config values
BACKUP_FOLDER=/tmp/backup/
ENCRYPT_PASSPHRASE_FILE=./secret
CONFIG_FILE_FOLDERS=folders.conf
CONFIG_FILE_DBS=dbs.conf
CONFIG_FILE_DROPBOX_UPLOADER=~/.dropbox_uploader

###################
# UTILITIES
###################

ensure_folder_exists() {
	DIR=$@
		
	[[ ! -d "$DIR" ]] && echo "ERROR: Directory does not exist: $DIR" && return 1
	
	return 0
}

ensure_file_exists() {
	FILE=$@
	
	[[ ! -f "$FILE" ]] && echo "ERROR: File does not exist: $FILE" && return 1
	
	return 0
}


check_dependencies() {
	NOT_FOUND=""
	for i in $DEPENDENCIES; do
	    type -p $i > /dev/null || NOT_FOUND="$NOT_FOUND $i"
	done
	
	[[ -z $NOT_FOUND ]] && return 0
	
	echo -e "Error: Required program(s) could not be found: $NOT_FOUND"
	exit 1
}

verify() {
	if [[ $DEBUG != 0 ]]; then
	    echo "VERSION: $VERSION"
	    uname -a 2> /dev/null && true
	fi

	check_dependencies

	ensure_folder_exists $BACKUP_FOLDER || exit 1

	ensure_file_exists $CONFIG_FILE_DROPBOX_UPLOADER || exit 1
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

upload() {
	LOCAL_PATH="$@"
	REMOTE_FILE=$(basename $LOCAL_PATH)
	
	[[ -z $REMOTE_FILE ]] && echo "error" && return 1
	[[ ! -f "$LOCAL_PATH" ]] && echo "file does not exist: $LOCAL_PATH" && return 1
	
	REMOTE_PATH="/backup/$NOW/$REMOTE_FILE"
		
	DROPBOX_UPLOADER="./vendor/dropboxuploader/dropbox_uploader.sh -q -f $CONFIG_FILE_DROPBOX_UPLOADER "
	
	[[ $DEBUG != 0 ]] && echo "] upload to dropbox: $LOCAL_PATH $REMOTE_PATH"
	
	return 0

	$DROPBOX_UPLOADER upload $LOCAL_PATH $REMOTE_PATH
}

build_file_path() {
	NAME=$1
	EXTENSION=$2
	
	[[ -z "$NAME" ]] && echo "ERROR: build_file_path(): no argument given." && return 1
	[[ -z "$EXTENSION" ]] && echo "ERROR: build_file_path(): parameter EXTENSION is empty." && return 1
	
	OUTPUT_FILE=${NAME}_${NOW}.$EXTENSION
	
	echo ${BACKUP_FOLDER}$OUTPUT_FILE
	
	return 0
}

backup_folder() {
	DIR=$1
	NAME=$2
	
	ensure_folder_exists $DIR || return 1

	[[ $DEBUG != 0 ]] && echo "] folder: $DIR"

	OUTPUT_FILE_PATH=$(build_file_path ${NAME} "tar.gz.gpg")
	
	tar c $DIR | compress | encrypt > $OUTPUT_FILE_PATH
	
	upload $OUTPUT_FILE_PATH	
}

backup_folders() {
	ensure_file_exists $CONFIG_FILE_FOLDERS || exit 1

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

send_notification() {
	DBNAME=$1
	LOG=$2
	
	echo $DBNAME
	echo $LOG
}

has_mysql_error() {
	# -s => true if file is not empty
	[[ -f "$@" ]] && [[ ! -s "$@" ]]
	
}

backup_database() {
	DBNAME=$1
	USER=$2
	PW=$3
	HOST=$4
	LOG=${BACKUP_FOLDER}/log/db_${DBNAME}.log
	
	[[ $DEBUG != 0 ]] && echo "] database: HOST=$HOST DB=$DBNAME USER=$USER"
	
	ensure_folder_exists $(dirname $LOG) || return 1
	
	# remove old LOGFILE
	rm -f $LOG
	
	OUTPUT_FILE_PATH=$(build_file_path ${DBNAME} "sql.gz.gpg")
	
	mysqldump -u $USER --password=$PW -h $HOST --log-error=$LOG $DBNAME | compress | encrypt > $OUTPUT_FILE_PATH
	
	has_mysql_error $LOG && send_notification $DBNAME $LOG

	upload $OUTPUT_FILE_PATH
	
	return 0
}

backup_databases() {
	ensure_file_exists $CONFIG_FILE_DBS || exit 1

	while read -r DBNAME USER PW HOST; do
		[[ -z $DBNAME ]]  && continue # skip empty lines
		[[ -z $USER ]]  && continue # TODO log error
		[[ -z $HOST ]]  && HOST=localhost

		backup_database "$DBNAME" "$USER" "$PW" "$HOST"
	done < ${CONFIG_FILE_DBS}
}

########################
# MAIN
########################

verify

# TODO: backup-folder as parameter
# TODO: dropbox-uploader-config-file as parameter

backup_databases
backup_folders
