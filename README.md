# cloudbackup
Backup files and database dumps to dropbox


## Extract backup file

Folder:

    gpg --decrypt --passphrase-file secret folderxyz_2015-12-21.tar.gz.gpg | tar -xvzf -

SQL-Dump

	gpg --decrypt --passphrase-file secret mydb_2015-12-21.sql.gz.gpg | gunzip > mydb.sql

