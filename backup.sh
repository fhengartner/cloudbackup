#!/bin/bash
########################################################################
#
# Dropbox Uploader
#
# Copyright (C) 2015 Florian Hengartner <fhengartner@gmail.com>
#
# Features:
# - compress & encrypt folders and mysql database dumps
# - upload backupfiles to dropbox
# - remove old local & remote files
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
DEBUG=0

# dont edit these
DEPENDENCIES="gpg mysqldump basename dirname"
VERSION="0.5"
EXITSTATUS=0

###################
# UTILITIES
###################

date_minus_days() {
	local DAYS=$1
	
	# abort if DAYS is not an integer
	[[ "$DAYS" =~ ^-?[0-9]+$ ]] || return 1
	
	if [ "${OSTYPE:0:6}" = "darwin" ]; then
		date -v-${DAYS}d +"%Y-%m-%d" || return 1
	elif [ "${OSTYPE:0:7}" = "freebsd" ]; then
		date -v-${DAYS}d +"%Y-%m-%d" || return 1
	elif [ "${OSTYPE:0:5}" = "linux" ]; then
		date +"%Y-%m-%d" -d "-${DAYS} day ago" || return 1
	else
		error "date_minus_days() not implemented for $OSTYPE"
	fi
	
	return 0
}

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
	
	ensure_file_exists "DROPBOX_UPLOADER_SH" "$DROPBOX_UPLOADER_SH"
}

usage() { 
	echo -e "Backup to Dropbox v$VERSION"
	echo -e "Usage: $0 <configfile> [-q|-v|-n] "

	echo -e "\nOptional parameters:"
	echo -e "\t-q\tQuiet mode"
	echo -e "\t-v\tVerbose mode"
	echo -e "\t-n\tNo upload"
	echo -e "\t-f <FILE> path to FOLDERS configuration-file"
	echo -e "\t-d <FILE> path to DATABASES configuration-file"
	
	exit 1;
}

parse_arguments() {
	while getopts ":qvnd:f:" o; do
	    case "${o}" in
	        q) DEBUG=0;;
	        v) DEBUG=1;;
			n) SKIP_UPLOAD=1;;
			d) CONFIG_FILE_DBS=$OPTARG;;
			f) CONFIG_FILE_FOLDERS=$OPTARG;;
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
	gpg --batch --no-tty --trust-model always \
		--symmetric --passphrase-file $ENCRYPT_PASSPHRASE_FILE
}

# upload file to dropbox
upload() {
	local LOCAL_PATH="$*"
	local REMOTE_FILE=$(basename $LOCAL_PATH)
	
	[[ ! -f "$LOCAL_PATH" ]] && echo -e "ERROR: LOCAL_PATH does not exist: $LOCAL_PATH" && return 1
	[[ -z $REMOTE_FILE ]] && echo -e "ERROR: REMOTE_FILE is empty LOCAL_PATH=$LOCAL_PATH" && return 1
	
	local REMOTE_PATH="/backup/$NOW/$REMOTE_FILE"
		
	[[ $DEBUG != 0 ]] && echo "] upload to dropbox: $LOCAL_PATH $REMOTE_PATH"
	
	[[ $SKIP_UPLOAD == 1 ]] && return 0

	$DROPBOX_UPLOADER upload $LOCAL_PATH $REMOTE_PATH || { echo "] WARN: unable to upload ${LOCAL_PATH} to ${REMOTE_PATH}"; return 1; }
}

build_file_path() {
	local NAME=$1
	local DATE=$2
	local EXTENSION=$3
	
	[[ -z "$NAME" ]] && echo "ERROR: build_file_path(): no argument given." && return 1
	[[ -z "$DATE" ]] && echo "ERROR: build_file_path(): parameter DATE is empty." && return 1
	[[ -z "$EXTENSION" ]] && echo "ERROR: build_file_path(): parameter EXTENSION is empty." && return 1
	
	local OUTPUT_FILE=${NAME}_${DATE}.$EXTENSION
	
	echo ${BACKUP_FOLDER}$OUTPUT_FILE
	
	return 0
}

backup_folder() {
	local SOURCE_FOLDER=$1
	local NAME=$2
	local EXCLUDEPATHS=$3
	
	ensure_folder_exists "SOURCE_FOLDER" $SOURCE_FOLDER || return 1

	[[ $DEBUG != 0 ]] && echo "] folder: $SOURCE_FOLDER"

	local EXT="tar.gz.gpg"
	local OUTPUT_FILE_PATH=$(build_file_path ${NAME} ${NOW} ${EXT})
	
	EXCLUDE_STRING=""
	BAK_IFS=$IFS
	IFS=$':'
	for EXCLUDEPATH in $EXCLUDEPATHS; do
		EXCLUDE_STRING="$EXCLUDE_STRING --exclude=${EXCLUDEPATH}"
	done
	IFS=$BAK_IFS
	
	tar -cf - $EXCLUDE_STRING "$SOURCE_FOLDER" | compress | encrypt  > "$OUTPUT_FILE_PATH" || { echo "] WARN: unable to compress/encrypt ${DIR}"; return 1; }
	
	upload "$OUTPUT_FILE_PATH" || return 1

	cleanup_local ${NAME} $EXT || return 1
	cleanup_remote ${NAME} $EXT || return 1

	return 0
}

# backup folders listed in config-file
backup_folders() {
	while read -r DIR NAME EXCLUDEPATH || [[ -n "$DIR" ]]; do
		[[ $DIR == \#* ]] && continue # ignore comment line
		[[ -z $DIR ]]  && continue # skip empty lines
		[[ -z $NAME ]]  && NAME=$(basename $DIR)
		[[ -z $NAME ]]  && echo "] WARN: unable to calculate NAME from '$DIR', skip line" && continue
	
		backup_folder "$DIR" "$NAME" "$EXCLUDEPATH" || { echo "] WARN: failed to backup ${DIR}"; EXITSTATUS=1; }
		
	done < ${CONFIG_FILE_FOLDERS}
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
	[[ -f "$*" ]] && [[ -s "$*" ]]	
}

# backup mysql database
backup_database() {
	local DBNAME=$1
	local USER=$2
	local PW=$3
	local HOST=$4
	local LOG=${LOG_FOLDER}/db_${DBNAME}.log
	
	[[ $DEBUG != 0 ]] && echo "] database: HOST=$HOST DB=$DBNAME USER=$USER"
	
	local EXT="sql.gz.gpg"
	local OUTPUT_FILE_PATH=$(build_file_path ${DBNAME} ${NOW} ${EXT})
	
	# has_mysql_error is only reliable if the old logfile is removed 
	rm -f $LOG
	
	mysqldump -u $USER --password=$PW -h $HOST --log-error=$LOG $DBNAME | compress | encrypt > $OUTPUT_FILE_PATH || { echo "] WARN: failed to backup ${DBNAME}"; return 1; }
	
	if [[ `has_mysql_error $LOG` ]]; then
		echo "] WARN: mysql error detected! $DBNAME"
		cat $LOG
		return 1
	fi

	upload "$OUTPUT_FILE_PATH" || return 1
	
	cleanup_local ${DBNAME} $EXT || return 1
	cleanup_remote ${DBNAME} $EXT || return 1
	
	return 0
}

cleanup_local() {
	[[ $DO_CLEANUP_LOCAL != 0 ]] || return 0

	local NAME=$1
	local EXT=$2
	
	local LOCAL_PATH=$(build_file_path ${NAME} ${CLEANUP_LOCAL_MAX_DAYS_DATE} ${EXT})

	# remove file
	if [[ -f $LOCAL_PATH ]]; then
		[[ $DEBUG != 0 ]] && echo "] cleanup local: $LOCAL_PATH"
		rm $LOCAL_PATH
	else
		[[ $DEBUG != 0 ]] && echo "] cleanup local, nothing done, file does not exist: $LOCAL_PATH"
	fi

	return 0
}

cleanup_remote() {
	[[ $DO_CLEANUP_REMOTE != 0 ]] || return 0

	local NAME=$1
	local EXT=$2

	###
	# Remove files older than 1 month, except:
	# if it is monday. (This retains 1 file every week.)
	###
	if [[ $DAY_OF_WEEK -ne 1 ]]; then
		delete_remote_file $NAME $MINUS_ONE_MONTH $EXT
	else
		[[ $DEBUG != 0 ]] && echo "] cleanup remote: no deletion of backup one week ago!"
	fi

	###
	# Remove files older than 1 year.
	###
	delete_remote_file $NAME $MINUS_ONE_YEAR $EXT
	
	return 0
}

delete_remote_file() {
	local NAME=$1
	local DATE_TO_DELETE=$2
	local EXT=$3
	
	local LOCAL_PATH=$(build_file_path ${NAME} ${DATE_TO_DELETE} ${EXT})
	local REMOTE_FILE=$(basename $LOCAL_PATH)
	local REMOTE_PATH="/backup/$MINUS_ONE_YEAR/$REMOTE_FILE"
	
	[[ $DEBUG != 0 ]] && echo "] cleanup remote $REMOTE_PATH"
	
	$DROPBOX_UPLOADER delete $REMOTE_PATH || true #ignore error, delete fails if file does not yet exist
	
	return 0
}


# backup databases listed in config-file
backup_databases() {
	i=0
	while read -r DBNAME USER PW HOST || [[ -n "$DBNAME" ]]; do
		[[ $DBNAME == \#* ]] && continue # ignore comment line
		[[ -z $DBNAME ]]  && continue # skip empty lines
		[[ -z $USER ]]  && echo -e "WARN: user is empty! ignoring line ${i} of $CONFIG_FILE_DBS" && continue
		[[ -z $HOST ]]  && HOST=localhost

		backup_database "$DBNAME" "$USER" "$PW" "$HOST" || { echo "] WARN: failed to backup ${DBNAME}"; EXITSTATUS=1; }
		
		let ++i
	done < ${CONFIG_FILE_DBS}
}

run() {
	[[ $DO_VERIFY != 0 ]] && verify
	[[ $DO_BACKUP_DATABASES != 0 ]] && backup_databases
	[[ $DO_BACKUP_FOLDERS != 0 ]] && backup_folders
	
	return 0
}

##################
# DATES
# initialize all dates now to minimize risk of
# obtaining different dates (e.g. at midnight).
##################
NOW=$(date +"%Y-%m-%d")
DAY_OF_WEEK=$(date "+%u")
MINUS_ONE_MONTH=$(date_minus_days 31) || error "Failed to set MINUS_ONE_MONTH"
MINUS_ONE_YEAR=$(date_minus_days 365) || error "Failed to set MINUS_ONE_YEAR"

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

# change to configfile folder.
# makes all paths relative to configfile.
cd $(dirname $CONFIGFILE)

# config values
SKIP_UPLOAD=${SKIP_UPLOAD:-0}
BACKUP_FOLDER=${BACKUP_FOLDER:-/tmp/backup/}
LOG_FOLDER=${LOG_FOLDER:-${BACKUP_FOLDER}/log/}
ENCRYPT_PASSPHRASE_FILE=${ENCRYPT_PASSPHRASE_FILE:-}
CONFIG_FILE_FOLDERS=${CONFIG_FILE_FOLDERS:-folders.conf}
CONFIG_FILE_DBS=${CONFIG_FILE_DBS:-dbs.conf}
CONFIG_FILE_DROPBOX_UPLOADER=${CONFIG_FILE_DROPBOX_UPLOADER:-~/.dropbox_uploader)}
NOTIFICATION_EMAIL_ADDRESS=${NOTIFICATION_EMAIL_ADDRESS:-}
DROPBOX_UPLOADER_SH=${DROPBOX_UPLOADER_SH:-./vendor/dropboxuploader/dropbox_uploader.sh}
DROPBOX_UPLOADER="${DROPBOX_UPLOADER_SH} -q -f $CONFIG_FILE_DROPBOX_UPLOADER "
CLEANUP_LOCAL_MAX_DAYS=${CLEANUP_LOCAL_MAX_DAYS:-5}
CLEANUP_LOCAL_MAX_DAYS_DATE=$(date_minus_days $CLEANUP_LOCAL_MAX_DAYS) || error "failed to set CLEANUP_LOCAL_MAX_DAYS_DATE: CLEANUP_LOCAL_MAX_DAYS=$CLEANUP_LOCAL_MAX_DAYS"
DO_RUN=${DO_RUN:-1}
DO_VERIFY=${DO_VERIFY:-1}
DO_BACKUP_DATABASES=${DO_BACKUP_DATABASES:-1}
DO_BACKUP_FOLDERS=${DO_BACKUP_FOLDERS:-1}
DO_CLEANUP_LOCAL=${DO_CLEANUP_LOCAL:-0}
DO_CLEANUP_REMOTE=${DO_CLEANUP_REMOTE:-0}
# end config values


# remove config-file path from arguments list
shift
parse_arguments $@

[[ $DO_RUN != 0 ]] && run

exit $EXITSTATUS
# THE END