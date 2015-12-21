#!/bin/bash
############
# fail on undefined variables
set -o nounset
############

source default.conf

cleanup() {
	# do in subshell because of 'cd'
 	$(cd $BACKUP_FOLDER && rm -f *.gpg)
}

testBackupDB() {
	# given
	EXPECTED="I AM THE DUMP: -u myuser1 --password=mypw1 -h myhost1 --log-error=/tmp/backup//log//db_db1.log db1"

	# when
	bash ../../backup.sh default.conf -q -d test1/dbs.conf -f test1/folders.conf

	# then
	ACTUAL=$(cat $BACKUP_FOLDER/db1*gpg)
	
	assertEquals "database dump is wrong or failed" "$EXPECTED" "$ACTUAL"
}

testDatabasesCount() {
	# given
	EXPECTED="$(grep -v '^#' test2/dbs.conf | wc -l)"

	# when
	bash ../../backup.sh default.conf -q -d test2/dbs.conf -f test2/folders.conf

	# then
	ACTUAL=$(ls -l $BACKUP_FOLDER/db*gpg | wc -l)
	
	assertEquals "number of dumps is wrong" "$EXPECTED" "$ACTUAL"
}

testFoldersCount() {
	# given
	EXPECTED="$(grep -v '^#' test3/folders.conf | wc -l)"

	# when
	bash ../../backup.sh default.conf -q -d test3/dbs.conf -f test3/folders.conf

	# then
	ACTUAL=$(ls -l $BACKUP_FOLDER/*tar.gz.gpg | wc -l)
	
	assertEquals "number of folders is wrong" "$EXPECTED" "$ACTUAL"
}

testExcludePaths() {
	# when
	bash ../../backup.sh default.conf -q -d test4/dbs.conf -f test4/folders.conf

	# then
	tar tvf $BACKUP_FOLDER/a*gpg | grep -e 'protected' -e 'runtime' -e 'session' > /dev/null

	assertFalse "folders should have been excluded from archive" "$?"
}

testNotExcludePaths() {
	# when
	bash ../../backup.sh default.conf -q -d test5/dbs.conf -f test5/folders.conf

	# then
	tar tvf $BACKUP_FOLDER/b*gpg | grep -e 'protected' -e 'runtime' -e 'session' > /dev/null

	assertTrue "folders should not have been excluded from archive" "$?"
}

testHasMysqlError() {
	export DO_RUN=false
	source ../../backup.sh default.conf -t -q -d test5/dbs.conf -f test5/folders.conf
	# undo settings from backup.sh (they interfer with shunit2)
	set +o errexit
	set +o pipefail
	set +o noglob
	
	TMPFILE=$(mktemp)
	has_mysql_error $TMPFILE
	assertFalse "has_mysql_error: expected false" "$?"

	echo "CONTENT" > $TMPFILE
	assertTrue "has_mysql_error: expected true" "$?"
}

testCleanupLocal() {
	# given
	FILE1=$BACKUP_FOLDER/a_$(date -v-5d +"%Y-%m-%d")".tar.gz.gpg"
	FILE2=$BACKUP_FOLDER/db1_$(date -v-5d +"%Y-%m-%d")".sql.gz.gpg"
	
	touch $FILE1 $FILE2
	
	# when
	bash ../../backup.sh test7/backup.conf -q -d test7/dbs.conf -f test7/folders.conf
	
	# then
	[[ -f $FILE1 ]]
	assertFalse "failed to cleanup $FILE1" "$?"

	[[ -f $FILE2 ]]
	assertFalse "failed to cleanup $FILE2" "$?"
}

setUp() {
	cleanup
}

# load shunit2
source ../../vendor/shunit2/source/2.1/src/shunit2