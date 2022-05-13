USE master;
IF EXISTS(SELECT * FROM sys.procedures WHERE object_id = OBJECT_ID(N'backupDatabases'))
BEGIN
	DROP PROCEDURE backupDatabases;
END
GO
CREATE PROCEDURE backupDatabases
    @backup_directory AS VARCHAR(1024) = NULL,
	@backup_directory_copy AS VARCHAR(1024) = NULL,
	@include_databases AS VARCHAR(MAX) = 'ALL',
	@exclude_databases AS VARCHAR(MAX) = 'NONE',
	@backup_type AS TINYINT = 0,
	@append_date AS TINYINT = 1
AS
BEGIN
	SET NOCOUNT ON;
	DECLARE @run_backup BIT;
	SELECT @run_backup = 1;
	DECLARE @run_message VARCHAR(MAX);
	DECLARE @run_error BIT;
	SELECT @run_error = 0;
	DECLARE @database_name VARCHAR(128);
	DECLARE @I INT;

	-- ACTIVATE COMMAND LINE ACCESS FOR FILE INTERACTION
	DECLARE @show_advanced_options BIT;
	SELECT @show_advanced_options = CONVERT(INT, value) FROM sys.configurations WHERE name = 'show advanced options'; 
	IF @show_advanced_options = 0
	BEGIN
		EXEC sp_configure 'show advanced options', '1';
		WAITFOR DELAY '00:00:03';
		RECONFIGURE WITH OVERRIDE;
	END;
	DECLARE @cmdshell_active BIT;
	SELECT @cmdshell_active = CONVERT(INT, value) FROM sys.configurations WHERE name = 'xp_cmdshell';
	IF @cmdshell_active = 0
	BEGIN
		EXEC sp_configure 'xp_cmdshell', '1';
		WAITFOR DELAY '00:00:03';
		RECONFIGURE WITH OVERRIDE;
	END;
	
	-- IF @backup_directory IS NULL USE THE DEFAULT BACKUP DIRECTORY.
	IF @backup_directory IS NULL
	BEGIN
		IF OBJECT_ID('tempdb..#Instance_Backup_Directory') IS NOT NULL
			DROP TABLE #Instance_Backup_Directory;
		CREATE TABLE [#Instance_Backup_Directory] (
			ID int NOT NULL IDENTITY(1,1),
			[directory_ID] char(15) NOT NULL,
			[directory_path] nvarchar(256) NOT NULL
		);
		INSERT INTO #Instance_Backup_Directory
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory';
		SELECT TOP 1 @backup_directory = directory_path FROM #Instance_Backup_Directory;
	END;

	-- CONFIRM THE INSTANCE HAS ACCESS TO THE BACKUP DIRECTORIES
	DECLARE @OS_command VARCHAR(8000);
	IF OBJECT_ID('tempdb..#OS_command_results') IS NOT NULL
		BEGIN
		DROP TABLE #OS_command_results;
		END
	CREATE TABLE #OS_command_results (
		ID INT IDENTITY(1,1) PRIMARY KEY,
		command_result VARCHAR(8000)
	);
	IF (SELECT RIGHT(@backup_directory, 1)) = '\' OR (SELECT RIGHT(@backup_directory, 1)) = '/'
	BEGIN
		SELECT @backup_directory = LEFT(@backup_directory, LEN(@backup_directory)-1);
	END;
	SELECT @OS_command = CONCAT('if exist "', @backup_directory, '" (echo 1) ELSE (echo 0)');
	INSERT INTO #OS_command_results EXEC xp_cmdshell @command_string = @OS_command;
	IF (SELECT TOP 1 CONVERT(BIT, command_result) FROM #OS_command_results) = 0
	BEGIN
		SELECT @run_backup = 0;
		SELECT @run_message = CONCAT('Error: Cannot access the @backup_directory path "', @backup_directory, '".');
	END
	ELSE
	BEGIN
		SELECT @run_message = CONCAT('Confirmed: The @backup_directory path "', @backup_directory,'" is accessible.');
	END;
	IF @run_backup = 1 AND @backup_directory_copy IS NOT NULL
	BEGIN
		IF (SELECT RIGHT(@backup_directory_copy, 1)) = '\' OR (SELECT RIGHT(@backup_directory_copy, 1)) = '/'
		BEGIN
			SELECT @backup_directory_copy = LEFT(@backup_directory_copy, LEN(@backup_directory_copy)-1);
		END;
		TRUNCATE TABLE #OS_command_results;
		SELECT @OS_command = CONCAT('if exist "', @backup_directory_copy, '" (echo 1) ELSE (echo 0)');
		INSERT INTO #OS_command_results EXEC xp_cmdshell @command_string = @OS_command;
		IF (SELECT TOP 1 CONVERT(BIT, command_result) FROM #OS_command_results) = 0
		BEGIN
			SELECT @run_backup = 0;
			SELECT @run_message = CONCAT(@run_message, CHAR(13), 'Error: Cannot access the @backup_directory_copy path "', @backup_directory_copy, '".');
		END
		ELSE
		BEGIN
			SELECT @run_message = CONCAT(@run_message, CHAR(13), 'Confirmed: The @backup_directory_copy path "', @backup_directory_copy,'" is accessible.');
		END;
	END;

	-- IF ACCESS TO SPECIFIED DIRECTORIES IS TRUE, CONTINUE WITH BACKUP COMMAND
	IF @run_backup = 1
	BEGIN
		-- BUILD LIST OF #Selected_Databases
		IF OBJECT_ID('tempdb..#All_Databases') IS NOT NULL
			BEGIN
			DROP TABLE #All_Databases;
			END
		CREATE TABLE #All_Databases (
			ID INT IDENTITY(1,1) PRIMARY KEY,
			database_name VARCHAR(128)
		);
		INSERT INTO #All_Databases SELECT [name] AS 'database_name' FROM sys.databases WHERE [state] = 0 AND [name] <> 'tempDB' AND [name] <> 'master' AND [name] <> 'msdb' AND [name] <> 'model';
		IF OBJECT_ID('tempdb..#Selected_Databases') IS NOT NULL
			BEGIN
			DROP TABLE #Selected_Databases;
			END
		CREATE TABLE #Selected_Databases (
			ID INT IDENTITY(1,1) PRIMARY KEY,
			database_name VARCHAR(MAX)
		);
		DECLARE @All_Databases_Count INT;
		SELECT @All_Databases_Count = COUNT(*) FROM #All_Databases;
		DECLARE @include_databases_list VARCHAR(MAX);
		SELECT @include_databases_list = @include_databases + ',';
		DECLARE @exclude_databases_list VARCHAR(MAX);
		SELECT @exclude_databases_list = @exclude_databases + ',';	
		DECLARE @add_database BIT = 0;
		SELECT @I = 1;
		WHILE (@I <= @All_Databases_Count)
		BEGIN
			SELECT @database_name = database_name FROM #All_Databases WHERE ID = @I;
			IF (UPPER(@include_databases_list) = 'ALL,' OR CHARINDEX(@database_name+',', @include_databases_list) <> 0)
				SELECT @add_database = 1;
			IF ((UPPER(@exclude_databases_list) = 'ALL,' AND CHARINDEX(@database_name+',', @include_databases_list) = 0) OR CHARINDEX(@database_name+',', @exclude_databases_list) <> 0)
				SELECT @add_database = 0;
			IF (@add_database = 1)
				INSERT INTO #Selected_Databases (database_name) VALUES (@database_name);
			SELECT @add_database = 0;
			SELECT @I = @I + 1;
		END
		DECLARE @Selected_Databases_Count INT;
		SELECT @Selected_Databases_Count = COUNT(*) FROM #Selected_Databases;

		-- RECORD DATABASE EDITION (Used to determine backup compression.  All backups will be compressed unless the edition is MSSQL Express.)
		DECLARE @database_edition VARCHAR(100);
		SELECT @database_edition = CONVERT(VARCHAR(100), SERVERPROPERTY('Edition'));
		DECLARE @is_mssql_express BIT;
		IF CHARINDEX('Express', @database_edition) > 0
		BEGIN
			SELECT @is_mssql_express = 1;
		END
		ELSE
		BEGIN
			SELECT @is_mssql_express = 0;
		END;

		-- COMPLETE BACKUP(S) FOR ALL #Selected_Databases
		DECLARE @sql_backup VARCHAR(MAX);
		DECLARE @sql_backup_with VARCHAR(MAX);
		DECLARE @file_name VARCHAR(256);
		SELECT @I = 1;
		WHILE (@I <= @Selected_Databases_Count)
		BEGIN
			SELECT @database_name = database_name FROM #Selected_Databases WHERE ID = @I;
			SELECT @file_name = @database_name;
			IF @append_date = 1
			BEGIN
				SELECT @file_name = CONCAT(@file_name, '_', CONVERT(VARCHAR(8),GETDATE(),112));
			END
			ELSE IF @append_date = 2 
			BEGIN
				SELECT @file_name = CONCAT(@file_name, '_', CONVERT(VARCHAR(8),GETDATE(),112));
				SELECT @file_name = CONCAT(@file_name, '_', REPLACE(CONVERT(VARCHAR(8),GETDATE(),108),':',''));
			END;
			IF @backup_type = 0
			BEGIN
				SELECT @file_name = CONCAT(@file_name, '.bak');
				IF @is_mssql_express < 1
				BEGIN
					SELECT @sql_backup_with = ' WITH CHECKSUM, COMPRESSION, INIT, NAME=''BLM-SE backupDatabases Stored Procedure''';
				END
				ELSE
				BEGIN
					SELECT @sql_backup_with = ' WITH CHECKSUM, INIT, NAME=''BLM-SE backupDatabases Stored Procedure''';
				END;
			END
			ELSE IF @backup_type = 1
			BEGIN
				SELECT @file_name = CONCAT(@file_name, '.dif');
				IF @is_mssql_express < 1
				BEGIN
					SELECT @sql_backup_with = ' WITH CHECKSUM, COMPRESSION, DIFFERENTIAL, INIT, NAME=''BLM-SE backupDatabases Stored Procedure''';
				END
				ELSE
				BEGIN
					SELECT @sql_backup_with = ' WITH CHECKSUM, DIFFERENTIAL, INIT, NAME=''BLM-SE backupDatabases Stored Procedure''';
				END;
			END
			ELSE IF @backup_type = 2
			BEGIN
				SELECT @file_name = CONCAT(@file_name, '.trn');
				IF @is_mssql_express < 1
				BEGIN
					SELECT @sql_backup_with = ' WITH CHECKSUM, COMPRESSION, NAME=''BLM-SE backupDatabases Stored Procedure''';
				END
				ELSE
				BEGIN
					SELECT @sql_backup_with = ' WITH CHECKSUM, NAME=''BLM-SE backupDatabases Stored Procedure''';
				END;
			END;
			ELSE
			BEGIN
				SELECT @file_name = CONCAT(@file_name, '.bak');
				IF @is_mssql_express < 1
				BEGIN
					SELECT @sql_backup_with = ' WITH CHECKSUM, COPY_ONLY, COMPRESSION, NAME=''BLM-SE backupDatabases Stored Procedure''';
				END
				ELSE
				BEGIN
					SELECT @sql_backup_with = ' WITH CHECKSUM, COPY_ONLY, NAME=''BLM-SE backupDatabases Stored Procedure''';
				END;
			END;
			IF @backup_type < 2
			BEGIN
				SELECT @sql_backup = CONCAT('BACKUP DATABASE [', @database_name, '] TO DISK = ''', @backup_directory, '\', @file_name, '''', @sql_backup_with, ';');
			END
			ELSE IF @backup_type = 2
			BEGIN
				SELECT @sql_backup = CONCAT('BACKUP LOG [', @database_name, '] TO DISK = ''', @backup_directory, '\', @file_name, '''', @sql_backup_with, ';');
			END
			ELSE IF @backup_type = 3
			BEGIN
				SELECT @sql_backup = CONCAT('BACKUP DATABASE [', @database_name, '] TO DISK = ''', @backup_directory, '\', @file_name, '''', @sql_backup_with, ';');
			END
			SELECT @run_message = CONCAT(@run_message, CHAR(13), 'Confirmed:  Backup "', @file_name, '" saved to @backup_directory successfully.');
			IF @backup_directory_copy IS NOT NULL
			BEGIN
				SELECT @sql_backup = CONCAT(@sql_backup, ' EXEC xp_cmdshell ''robocopy "', @backup_directory, '" "', @backup_directory_copy, '" ', @file_name, ''', NO_OUTPUT;');
				SELECT @run_message = CONCAT(@run_message, CHAR(13), 'Confirmed:  Backup "', @file_name, '" copied to @backup_directory_copy successfully.');
			END;
			EXEC(@sql_backup);
			SELECT @I = @I + 1;
		END;
	END;
	
	-- DEACTIVATE COMMAND LINE ACCESS IF PREVIOUSLY INACTIVE
	IF @backup_directory_copy IS NOT NULL AND @cmdshell_active = 0
	BEGIN
		EXEC sp_configure 'xp_cmdshell', '0';
		WAITFOR DELAY '00:00:03';
		RECONFIGURE WITH OVERRIDE;
	END;
	IF @backup_directory_copy IS NOT NULL AND @show_advanced_options = 0
	BEGIN
		EXEC sp_configure 'show advanced options', '0';
		WAITFOR DELAY '00:00:03';
		RECONFIGURE WITH OVERRIDE;
	END;

	-- PROVIDE FINAL CONFIRMATION / ERROR
	IF @run_backup = 1
	BEGIN
		SELECT @run_message = CONCAT('-----', CHAR(13), 'BACKUP SUCCESSFUL', CHAR(13), @run_message);
		PRINT @run_message;
	END
	ELSE
	BEGIN
		SELECT @run_message = CONCAT('-----', CHAR(13), 'BACKUP CANCELLED', CHAR(13), @run_message);
		RAISERROR(@run_message, 16, 1);
	END;
	SET NOCOUNT OFF;
END;