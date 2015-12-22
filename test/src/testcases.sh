#!/bin/bash

source test1/backup.conf

# fail on undefined variables
set -o nounset
# allow globbing
set +o noglob


backup_sh() {
	bash ../../backup.sh $1/backup.conf -q -d test/src/$1/dbs.conf -f test/src/$1/folders.conf
}

cleanup() {
	# do in subshell because of 'cd'
 	$(cd $BACKUP_FOLDER && rm -f *.gpg)
}

testBackupDB() {
	# given
	EXPECTED="I AM THE DUMP: -u myuser1 --password=mypw1 -h myhost1 --log-error=/tmp/backup//log//db_db1.log db1"

	# when
	backup_sh test1

	# then
	ACTUAL=$(cat $BACKUP_FOLDER/db1*gpg 2>/dev/null)

	assertEquals "database dump is wrong or failed." "$EXPECTED" "$ACTUAL"
}

testDatabasesCount() {
	# given
	EXPECTED="$(grep -v '^#' test2/dbs.conf | wc -l)"

	# when
	backup_sh test2

	# then
	ACTUAL=$(ls -l $BACKUP_FOLDER/db*gpg 2>/dev/null | wc -l)
	
	assertEquals "number of dumps is wrong." "$EXPECTED" "$ACTUAL"
}

testFoldersCount() {
	# given
	EXPECTED="$(grep -v '^#' test3/folders.conf | wc -l)"

	# when
	backup_sh test3

	# then
	ACTUAL=$(ls -l $BACKUP_FOLDER/*tar.gz.gpg 2>/dev/null | wc -l)
	
	assertEquals "number of folders is wrong." "$EXPECTED" "$ACTUAL"
}

testExcludePaths() {
	# when
	backup_sh test4

	# then
	tar tvf $BACKUP_FOLDER/a*gpg 2> /dev/null | grep -e 'protected' -e 'runtime' -e 'session' > /dev/null

	assertFalse "folders should have been excluded from archive." "$?"
}

testNotExcludePaths() {
	# when
	backup_sh test5

	# then
	tar tvf $BACKUP_FOLDER/b*gpg 2> /dev/null | grep -e 'protected' -e 'runtime' -e 'session' > /dev/null

	assertTrue "folders should not have been excluded from archive." "$?"
}

testHasMysqlError() {
	export DO_RUN=false
	local DIR=
	source ../../backup.sh test6/backup.conf -q -d test/src/test6/dbs.conf -f test/src/test6/folders.conf
	# undo settings from backup.sh (they interfer with shunit2)
	set +o errexit
	set +o pipefail
	set +o noglob
	
	TMPFILE=$(mktemp)
	has_mysql_error $TMPFILE
	assertFalse "has_mysql_error: expected false." "$?"

	echo "CONTENT" > $TMPFILE
	assertTrue "has_mysql_error: expected true." "$?"
}

testCleanupLocal() {
	# given
	FILE1=$BACKUP_FOLDER/a_$(date -v-5d +"%Y-%m-%d")".tar.gz.gpg"
	FILE2=$BACKUP_FOLDER/db1_$(date -v-5d +"%Y-%m-%d")".sql.gz.gpg"
	
	touch $FILE1 $FILE2
	
	# when
	backup_sh test7
	
	# then
	[[ -f $FILE1 ]]
	assertFalse "failed to cleanup $FILE1" "$?"

	[[ -f $FILE2 ]]
	assertFalse "failed to cleanup $FILE2" "$?"
}

setUp() {
	echo ""
	cleanup
	#echo -en "\nTest: "
}

# load shunit2
source ../../vendor/shunit2/source/2.1/src/shunit2