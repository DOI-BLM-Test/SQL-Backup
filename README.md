# SQL-Backup
Back up and Restore - does not effect enterprise backup solutions

-- This sql file creates initial, compressed backup files within @backup_directory and optionally copies the backup to @backup_directory_copy.
-- The stored procedure supports full, differential and transaction log backups.  Use SQL Server Agent to schedule regular backups.
-- The stored procedure prints messages for feedback when running within SSMS.  It also returns a 1 (success) or 0 (failure) if running as part of a larger process or SQL Agent job.
-- PROCEDURE VARIABLES
-- 	@backup_directory = The location to save backup files.  The service account used by SQL Server must have write access to the directory.  If omitted, the stored procedure will use the default backup directory for the instance.
-- 	@backup_directory_copy = The location to save backup file copies.  The service account used by SQL Server must have write access to the directory.  If the MSSQL instance runs with a virtual service account or under local system, configure the AD computer account on the remote directory.
--	@include_databases = The databases included in backup command.  Valid values are 'ALL', 'NONE', a single database name, or a list of databases separated by commas.  Default = 'ALL'
--  @exclude_databases = The databases excluded from the backup command.  Valid values are 'ALL', 'NONE', a single database name, or a list of databases separated by commas.  Default = 'NONE'
--  @backup_type = Execute full (.bak), differential (.dif) or transaction log (.trn) backups.  0 = full, 1 = differential, 2 = transaction log, 3 = full backup that is separate from the backup series (does not affect enterprise backups).  Default = 0
--  @append_date = Add a date/datetime stamp to the file name.  0 = append no date/datetime, 1 = append the date to the file in the format yyyymmdd, 2 = append date and time to the file in the format yyyymmdd_hhmmss.  Default = 1.

-- EXAMPLE 1:  Complete full backups of all databases within the instance to the instance's default backup directory.
--   USE master;
--   EXEC backupDatabases;
--   Note:  This works because the default value for @include_databases = 'ALL', the default for @exclude_databases = 'NONE' and the stored procedure uses the default backup directory for the instance when @backup_directory is omitted.
-- EXAMPLE 2:  Complete full backups of "dBase9" to @backup_directory.
--   USE master;
--   EXEC backupDatabases @backup_directory = 'D:\MSSQLSERVER_BACKUPS', @include_databases = 'dBase9';
--   Note:  To include multiple databases within the backup list, provide a comma-delimited list (i.e. @include_databases = 'dBase8, dBase9')
-- EXAMPLE 3:  Complete full backups of all databases within the instance to @backup_directory except 'dBase9'.
--   USE master;
--   EXEC backupDatabases @backup_directory = 'D:\MSSQLSERVER_BACKUPS', @exclude_databases = 'dBase9';
--   Note:  To exclude multiple databases within the backup list, provide a comma-delimited list (i.e. @exclude_databases = 'dBase8, dBase9')
-- EXAMPLE 4:  Complete differential backups of all databases within the instance to the default backup directory and copy to @backup_directory_copy.
--   USE master;
--   EXEC backupDatabases @backup_directory_copy = '\\xxxxxx.xxx.xxx.xxx\MSSQLSERVER_BACKUPS', @backup_type = 1;
-- EXAMPLE 5:  Complete transaction log backups of all databases within the instance to @backup_directory and @backup_directory_copy.  Append the datetime to the filename.
--   USE master;
--   EXEC backupDatabases @backup_directory_copy = '\\\xxxxxx.xxx.xxx.xxx\MSSQLSERVER_BACKUPS', @backup_type = 2, @append_date = 2;
-- EXAMPLE 6:  Complete a full backup of "dBase9" to the default backup directory that is independent from the existing backup series
--   USE master;
--   EXEC backupDatabases @include_databases = 'dBase9', @backup_type = 3;
--   Note:  If the enterprise backup software runs transaction log backups, always use @backup_type = 3 (full backup independent from the series).
