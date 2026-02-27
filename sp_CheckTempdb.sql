IF OBJECT_ID('dbo.sp_CheckTempdb') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_CheckTempdb AS RETURN 0;');
GO


ALTER PROCEDURE [dbo].[sp_CheckTempdb]
    @Mode TINYINT = 99 
	, @Size CHAR(2) = 'MB'
    , @UsagePercent TINYINT = 50
	, @AvgReadStallMs INT = 100
	, @AvgWriteStallMs INT = 100
	, @Help BIT = 0
	, @VersionCheck BIT = 0

WITH RECOMPILE
AS
SET NOCOUNT ON;

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE 
    @Version VARCHAR(10) = NULL
	, @VersionDate DATETIME = NULL

SELECT
    @Version = '2026.2.1'
    , @VersionDate = '20260219';

/* Version check */
IF @VersionCheck = 1 BEGIN

	SELECT
		@Version AS VersionNumber
		, @VersionDate AS VersionDate

	RETURN;
	END;  

/* @Help = 1 */
IF @Help = 1 BEGIN
	PRINT '
/*
    sp_CheckTempdb from https://straightpathsql.com/

	Version: ' + @Version + ' updated ' + CONVERT(VARCHAR(10), @VersionDate, 101) + '
    	
    This stored procedure checks your SQL Server tempdb database for issues and 
    provides a list of findings with action items, or if you prefer, allows you 
    to review the current status of tempdb in a few different ways if you need
    to troubleshoot.
    
    Known limitations of this version:
    - sp_CheckTempdb only works Microsoft-supported versions of SQL Server, so 
    that means SQL Server 2016 or later.
    - sp_CheckTempdb will work with some earlier versions of SQL Server, but it 
    will skip a few checks. The results should still be valid and helpful, but you
    should really consider upgrading to a newer version.
    
    Parameters:

    @Mode  0=Show only problematic issues, unfiltered
           1=Summary data for all tempdb files
		   2=Summary results of what is currently using space in tempdb
		    (includes data and log files)
           3=Check for tempdb contention (SQL Server 2019 and later only)

    @Size ''MB'' displays sizes in megabytes
          ''GB'' displays sizes in gigabytes

    @UsagePercent
	      0-100 indicates percentage of usage of tempdb files to check for
		  50% is the default

    @AvgReadStallMs
	      0-? indicates average value in milliseconds for read stalls
		  to report on if exceeded
		  100ms is the default

    @AvgWriteStallMs
	      0-? indicates average value in milliseconds for write stalls
		  to report on if exceeded
		  100ms is the default

    @VersionCheck use to check version number and date


    MIT License
    
    Copyright for portions of sp_CheckTempdb are also held by Brent Ozar Unlimited
    as part of sp_Blitz and are provided under the MIT license:
    https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/
    	
    All other copyrights for sp_CheckTempdb are held by Straight Path Solutions.
    
    Copyright 2026 Straight Path IT Solutions, LLC
    
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:
    
    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.
    
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

*/';
	RETURN;
	END;  

/* set some defaults */

IF OBJECT_ID('tempdb..#Results') IS NOT NULL
	DROP TABLE #Results;

CREATE TABLE #Results (
    CategoryID TINYINT
	, CheckID INT
    , [Importance] TINYINT
	, CheckName VARCHAR(50)
	, Issue NVARCHAR(1000)
	, DatabaseName NVARCHAR(255)
	, Details NVARCHAR(1000)
	, ActionStep NVARCHAR(1000)
	, ReadMoreURL XML
	);

/* SQL Server version check */	
DECLARE 
	@SQL NVARCHAR(4000)
	, @SQLVersion NVARCHAR(128)
	, @SQLVersionMajor DECIMAL(10,2)
	, @SQLVersionMinor DECIMAL(10,2);

IF OBJECT_ID('tempdb..#SQLVersions') IS NOT NULL
	DROP TABLE #SQLVersions;

CREATE TABLE #SQLVersions (
	VersionName VARCHAR(10)
	, VersionNumber DECIMAL(10,2)
	);

INSERT #SQLVersions
VALUES
	('2008', 10)
	, ('2008 R2', 10.5)
	, ('2012', 11)
	, ('2014', 12)
	, ('2016', 13)
	, ('2017', 14)
	, ('2019', 15)
	, ('2022', 16);

/* SQL Server version */
SELECT @SQLVersion = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));

SELECT 
	@SQLVersionMajor = SUBSTRING(@SQLVersion, 1,CHARINDEX('.', @SQLVersion) + 1 )
	, @SQLVersionMinor = PARSENAME(CONVERT(varchar(32), @SQLVersion), 2);


	/* check for unsupported version */	
IF @SQLVersionMajor < 11 BEGIN
	PRINT '
/*
    *** Unsupported SQL Server Version ***

    sp_CheckTempdb is supported only for execution on SQL Server 2012 and later.

	For more information about the limitations of sp_CheckTempdb, execute
    using @Help = 1

    *** EXECUTION ABORTED ***
    	   
*/';
	RETURN;
	END; 

IF @UsagePercent > 100
    SET @UsagePercent = 100

IF @UsagePercent < 0
    SET @UsagePercent = 0

DECLARE
    @NumberOfDataFiles INT
    , @NumberOfCPUCores INT;

SELECT @NumberOfDataFiles = COUNT([file_id])
FROM tempdb.sys.database_files
WHERE [type] = 0;

SELECT @NumberOfCPUCores = cpu_count
FROM sys.dm_os_sys_info;

CREATE TABLE #TraceFlag (
    TraceFlag VARCHAR(10)
    , [Status] BIT
    , [Global] BIT
    , [Session] BIT
	)

INSERT INTO #TraceFlag
EXEC ( ' DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');

IF @Mode IN (1,99) BEGIN
    IF OBJECT_ID('tempdb..#Properties') IS NOT NULL
    	DROP TABLE #Properties;
    
    CREATE TABLE #Properties (
        FileId INT
        , LogicalName sysname
        , FileType NVARCHAR(60)
        , [Filegroup] sysname
        , SizeInMB INT
        , Autogrowth NVARCHAR(20)
        , [MaxSize] NVARCHAR(50)
        , PhysicalName NVARCHAR(260)
        );
    
    INSERT #Properties
    SELECT
        f.[file_id]
        , f.[name]
        , f.[type_desc]
        , COALESCE(g.[name], 'Not Applicable')
        , f.[size]/128
        , CASE f.[growth]
            WHEN 0 THEN 'None'
            ELSE CASE f.[is_percent_growth]
                WHEN 0 THEN CONVERT(NVARCHAR(50), f.[growth]/128) + ' MB'
                WHEN 1 THEN CONVERT(NVARCHAR(50), f.[growth]) + ' percent'
                END
            END
        , CASE f.[growth]
            WHEN 0 THEN 'N/A'
    		ELSE CASE f.[max_size]
                WHEN 0 THEN 'No growth allowed'
                WHEN -1 THEN 'Unlimited growth'
                ELSE CONVERT(NVARCHAR(50), f.[max_size]/128) + ' MB'
                END
            END
        , f.[Physical_Name]
    FROM tempdb.sys.database_files f
    LEFT JOIN tempdb.sys.filegroups g
        ON f.data_space_id = g.data_space_id;
    
    SELECT *
    FROM #Properties
    ORDER BY 1;
    END;

IF @Mode IN (2) BEGIN

    IF @Size = 'MB' BEGIN

/* Usage summary */
        SELECT 
            CONVERT(NUMERIC(10,1),(SUM(total_page_count)/128.)) AS TotalSpaceMB
            , CONVERT(NUMERIC(10,1),(SUM(allocated_extent_page_count)/128.)) AS UsedSpaceMB
            , CONVERT(NUMERIC(10,1),(SUM(unallocated_extent_page_count)/128.)) AS FreespaceMB
            , CONVERT(NUMERIC(10,1),(SUM(user_object_reserved_page_count)/128.)) AS UserObjectSpaceMB
            , CONVERT(NUMERIC(10,1),(SUM(internal_object_reserved_page_count)/128.)) AS InternalObjectSpaceMB
            , CONVERT(NUMERIC(10,1),(SUM(version_store_reserved_page_count)/128.)) AS VersionStoreSpaceMB
            , CONVERT(NUMERIC(10,1),(SELECT SUM(size)/128. FROM tempdb.sys.database_files WHERE type = 1)) AS LogFileSizeMB
            , (SELECT CONVERT(NUMERIC(10,1),(used_log_space_in_bytes/1048576.)) FROM tempdb.sys.dm_db_log_space_usage) AS LogSpaceUsedMB
        FROM tempdb.sys.dm_db_file_space_usage

/* Data usage */
      ;WITH SessionInfo AS (
			SELECT DISTINCT
				u.session_id
			FROM (
				SELECT 
					session_id
				FROM tempdb.sys.dm_db_session_space_usage ss1 WITH (NOLOCK)
				WHERE session_id <> @@SPID
					AND (user_objects_alloc_page_count > 0 OR internal_objects_alloc_page_count > 0)
				UNION
				SELECT 
					session_id
				FROM tempdb.sys.dm_db_task_space_usage ts2 WITH (NOLOCK)
				WHERE session_id <> @@SPID
					AND (user_objects_alloc_page_count > 0 OR internal_objects_alloc_page_count > 0)
				) u
			)
		SELECT
			s.session_id
			, es.login_name AS LoginName
			, CONVERT(NUMERIC(10,1),ssu.SessionNetAllocationMB) AS SessionSpaceMB
			, CONVERT(NUMERIC(10,1),ssu.SessionNetAllocationUserSpaceMB) AS SessionUserSpaceMB
			, CONVERT(NUMERIC(10,1),ssu.SessionNetAllocationInternalSpaceMB) AS SessionInternalSpaceMB
			, CONVERT(NUMERIC(10,1),tsu.RunningNetAllocationMB) AS RunningSpaceMB
			, CONVERT(NUMERIC(10,1),tsu.RunningNetAllocationUserSpaceMB) AS RunningUserSpaceMB
			, CONVERT(NUMERIC(10,1),tsu.RunningNetAllocationInternalSpaceMB) AS RunningInternalSpaceMB
			, t.[text] AS StatementText
		FROM SessionInfo s
		INNER JOIN sys.dm_exec_sessions es
			ON s.session_id = es.session_id
		LEFT JOIN (
			SELECT
				ss.session_id
				, (ss.user_objects_alloc_page_count + ss.internal_objects_alloc_page_count 
					- ss.internal_objects_dealloc_page_count - ss.user_objects_dealloc_page_count ) / 128. AS SessionNetAllocationMB 
				, (ss.user_objects_alloc_page_count - ss.user_objects_dealloc_page_count) / 128. AS SessionNetAllocationUserSpaceMB
				, (ss.internal_objects_alloc_page_count - ss.internal_objects_dealloc_page_count) / 128. AS SessionNetAllocationInternalSpaceMB
			FROM tempdb.sys.dm_db_session_space_usage ss
			) ssu
			ON s.session_id = ssu.session_id
		LEFT JOIN (
			SELECT
				ts.session_id
				, SUM(ts.user_objects_alloc_page_count + ts.internal_objects_alloc_page_count 
					- ts.internal_objects_dealloc_page_count - ts.user_objects_dealloc_page_count ) / 128. AS RunningNetAllocationMB 
				, SUM(ts.user_objects_alloc_page_count - ts.user_objects_dealloc_page_count) / 128. AS RunningNetAllocationUserSpaceMB
				, SUM(ts.internal_objects_alloc_page_count - ts.internal_objects_dealloc_page_count) / 128. AS RunningNetAllocationInternalSpaceMB
			FROM tempdb.sys.dm_db_task_space_usage ts
			GROUP BY
				ts.session_id
			) tsu
			ON s.session_id = tsu.session_id
		LEFT JOIN sys.dm_exec_connections c
			ON c.session_id = s.session_id
		OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
		ORDER BY
			SessionSpaceMB DESC
			, RunningSpaceMB DESC;

/* Log usage */
       SELECT
           tst.[session_id]
           , s.[login_name] AS LoginName
           , tdt.[database_transaction_begin_time] AS TranStartTime
           , tdt.[database_transaction_log_record_count] AS LogRecords
           , CONVERT(NUMERIC(10,1), tdt.[database_transaction_log_bytes_used]/1048576.) AS LogUsedMB
           , CONVERT(NUMERIC(10,1), tdt.[database_transaction_log_bytes_reserved]/1048576.) AS LogBytesReservedMB
    	   , st.[text] AS OuterStatement
           , SUBSTRING(st.text, (r.statement_start_offset/2)+1,
                ((CASE r.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE r.statement_end_offset
                END - r.statement_start_offset)/2) + 1) AS StatementText
           , qp.[query_plan] AS QueryPlan
        FROM sys.dm_tran_database_transactions tdt
        INNER JOIN sys.dm_tran_session_transactions tst
            ON tst.[transaction_id] = tdt.[transaction_id]
        INNER JOIN sys.dm_exec_sessions s
            ON s.[session_id] = tst.[session_id]
        INNER JOIN sys.dm_exec_connections c
            ON c.[session_id] = tst.[session_id]
        LEFT OUTER JOIN sys.dm_exec_requests r
            ON r.[session_id] = tst.[session_id]
        CROSS APPLY sys.dm_exec_sql_text (c.[most_recent_sql_handle]) AS st
        OUTER APPLY sys.dm_exec_query_plan (r.[plan_handle]) AS qp
        WHERE DB_NAME (tdt.database_id) = 'tempdb'
    	AND tdt.[database_transaction_log_bytes_used] > 0
        ORDER BY LogUsedMB DESC;

        END;

    IF @Size = 'GB' BEGIN

        SELECT 
            CONVERT(NUMERIC(10,1),(SUM(total_page_count)/131072.)) AS TotalSpaceGB
            , CONVERT(NUMERIC(10,1),(SUM(allocated_extent_page_count)/131072.)) AS UsedSpaceGB
            , CONVERT(NUMERIC(10,1),(SUM(unallocated_extent_page_count)/131072.)) AS FreespaceGB
            , CONVERT(NUMERIC(10,1),(SUM(user_object_reserved_page_count)/131072.)) AS UserObjectSpaceGB
            , CONVERT(NUMERIC(10,1),(SUM(internal_object_reserved_page_count)/131072.)) AS InternalObjectSpaceGB
            , CONVERT(NUMERIC(10,1),(SUM(version_store_reserved_page_count)/131072.)) AS VersionStoreSpaceGB
            , CONVERT(NUMERIC(10,1),(SELECT SUM(size)/131072. FROM tempdb.sys.database_files WHERE type = 1)) AS LogFileSizeGB
            , (SELECT CONVERT(NUMERIC(10,1),(used_log_space_in_bytes/1048576./1024)) FROM tempdb.sys.dm_db_log_space_usage) AS LogSpaceUsedGB
        FROM tempdb.sys.dm_db_file_space_usage

/* Data usage */
      ;WITH SessionInfo AS (
			SELECT DISTINCT
				u.session_id
			FROM (
				SELECT 
					session_id
				FROM tempdb.sys.dm_db_session_space_usage ss1 WITH (NOLOCK)
				WHERE session_id <> @@SPID
					AND (user_objects_alloc_page_count > 0 OR internal_objects_alloc_page_count > 0)
				UNION
				SELECT 
					session_id
				FROM tempdb.sys.dm_db_task_space_usage ts2 WITH (NOLOCK)
				WHERE session_id <> @@SPID
					AND (user_objects_alloc_page_count > 0 OR internal_objects_alloc_page_count > 0)
				) u
			)
		SELECT
			s.session_id
			, es.login_name AS LoginName
			, CONVERT(NUMERIC(10,1),ssu.SessionNetAllocationGB) AS SessionSpaceGB
			, CONVERT(NUMERIC(10,1),ssu.SessionNetAllocationUserSpaceGB) AS SessionUserSpaceGB
			, CONVERT(NUMERIC(10,1),ssu.SessionNetAllocationInternalSpaceGB) AS SessionInternalSpaceGB
			, CONVERT(NUMERIC(10,1),tsu.RunningNetAllocationGB) AS RunningSpaceGB
			, CONVERT(NUMERIC(10,1),tsu.RunningNetAllocationUserSpaceGB) AS RunningUserSpaceGB
			, CONVERT(NUMERIC(10,1),tsu.RunningNetAllocationInternalSpaceGB) AS RunningInternalSpaceGB
			, t.[text] AS StatementText
		FROM SessionInfo s
		INNER JOIN sys.dm_exec_sessions es
			ON s.session_id = es.session_id
		LEFT JOIN (
			SELECT
				ss.session_id
				, (ss.user_objects_alloc_page_count + ss.internal_objects_alloc_page_count 
					- ss.internal_objects_dealloc_page_count - ss.user_objects_dealloc_page_count ) / 131072. AS SessionNetAllocationGB 
				, (ss.user_objects_alloc_page_count - ss.user_objects_dealloc_page_count) / 131072. AS SessionNetAllocationUserSpaceGB
				, (ss.internal_objects_alloc_page_count - ss.internal_objects_dealloc_page_count) / 131072. AS SessionNetAllocationInternalSpaceGB
			FROM tempdb.sys.dm_db_session_space_usage ss
			) ssu
			ON s.session_id = ssu.session_id
		LEFT JOIN (
			SELECT
				ts.session_id
				, SUM(ts.user_objects_alloc_page_count + ts.internal_objects_alloc_page_count 
					- ts.internal_objects_dealloc_page_count - ts.user_objects_dealloc_page_count ) / 131072. AS RunningNetAllocationGB 
				, SUM(ts.user_objects_alloc_page_count - ts.user_objects_dealloc_page_count) / 131072. AS RunningNetAllocationUserSpaceGB
				, SUM(ts.internal_objects_alloc_page_count - ts.internal_objects_dealloc_page_count) / 131072. AS RunningNetAllocationInternalSpaceGB
			FROM tempdb.sys.dm_db_task_space_usage ts
			GROUP BY
				ts.session_id
			) tsu
			ON s.session_id = tsu.session_id
		LEFT JOIN sys.dm_exec_connections c
			ON c.session_id = s.session_id
		OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
		ORDER BY
			SessionSpaceGB DESC
			, RunningSpaceGB DESC;

/* Log usage */
       SELECT
           tst.[session_id]
           , s.[login_name] AS LoginName
           , tdt.[database_transaction_begin_time] AS TranStartTime
           , tdt.[database_transaction_log_record_count] AS LogRecords
           , CONVERT(NUMERIC(10,1), tdt.[database_transaction_log_bytes_used]/1048576./1024.) AS LogUsedGB
           , CONVERT(NUMERIC(10,1), tdt.[database_transaction_log_bytes_reserved]/1048576./1024.) AS LogBytesReservedGB
    	   , st.[text] AS OuterStatement
           , SUBSTRING(st.text, (r.statement_start_offset/2)+1,
                ((CASE r.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE r.statement_end_offset
                END - r.statement_start_offset)/2) + 1) AS StatementText
           , qp.[query_plan] AS QueryPlan
        FROM sys.dm_tran_database_transactions tdt
        INNER JOIN sys.dm_tran_session_transactions tst
            ON tst.[transaction_id] = tdt.[transaction_id]
        INNER JOIN sys.dm_exec_sessions s
            ON s.[session_id] = tst.[session_id]
        INNER JOIN sys.dm_exec_connections c
            ON c.[session_id] = tst.[session_id]
        LEFT OUTER JOIN sys.dm_exec_requests r
            ON r.[session_id] = tst.[session_id]
        CROSS APPLY sys.dm_exec_sql_text (c.[most_recent_sql_handle]) AS st
        OUTER APPLY sys.dm_exec_query_plan (r.[plan_handle]) AS qp
        WHERE DB_NAME (tdt.database_id) = 'tempdb'
    	AND tdt.[database_transaction_log_bytes_used] > 0
        ORDER BY LogUsedGB DESC;

		END;

	END;

IF @Mode IN (3) BEGIN

/* Check for version prior to SQL Server 2019 */
    IF @SQLVersionMajor < 15 BEGIN
        PRINT '
/*
    *** Unsupported SQL Server Version ***

    @Mode = 3 is supported only for execution on SQL Server 2019 and later.

	Sorry, but we can''t check for tempdb contention with this version.

    *** EXECUTION ABORTED ***
    	   
*/';
        RETURN;
        END; 

/* 
Check for allocation or metadata contention in tempdb
Query modified from original written by Haripriya Naidu: https://gohigh.substack.com/p/query-to-check-tempdb-contention
*/
    IF @SQLVersionMajor >= 15 BEGIN

        SELECT 
            er.session_id
            , er.wait_type AS WaitType
            , er.wait_resource AS WaitResource
            , OBJECT_NAME(page_info.[object_id],page_info.database_id) AS ObjectName
            , er.blocking_session_id AS BlockingSessionID
    		, er.command AS Command
            , SUBSTRING(st.text, (er.statement_start_offset/2)+1,   
                ((CASE er.statement_end_offset  
                      WHEN -1 THEN DATALENGTH(st.text)  
                     ELSE er.statement_end_offset  
                     END - er.statement_start_offset)/2) + 1) AS StatementText
            , page_info.database_id AS DatabaseID
            , page_info.[file_id] AS FileID
            , page_info.page_id AS PageID
            , page_info.[object_id] AS ObjectID
            , page_info.index_id AS IndexID
            , page_info.page_type_desc AS PageTypeDesc
            , CASE 
                WHEN page_info.page_type_desc IN('SGAM_PAGE','GAM_PAGE', 'PFS_PAGE') 
                    AND wait_type IN ('PAGELATCH_SH','PAGELATCH_UP','PAGELATCH_EX')
                    THEN 'ALLOCATION CONTENTION'
                WHEN page_info.page_type_desc IN ('DATA_PAGE', 'INDEX_PAGE') 
                    AND wait_type IN ('PAGELATCH_SH','PAGELATCH_UP','PAGELATCH_EX')
                    THEN 'METADATA CONTENTION'
                END AS AllocationType
        FROM master.sys.dm_exec_requests AS er
        CROSS APPLY master.sys.dm_exec_sql_text(er.sql_handle) AS st 
        CROSS APPLY master.sys.fn_PageResCracker (er.page_resource) AS r /*database ID, file ID, page ID SQL2019*/
        CROSS APPLY master.sys.dm_db_page_info(r.[db_id], r.[file_id], r.page_id, 'DETAILED') AS page_info /*replace dbcc page SQL2019*/
        WHERE er.wait_type LIKE 'PAGELATCH%'
            AND er.wait_resource LIKE '2:%';
    
        END;

    END;
IF @Mode IN (0,99) BEGIN

/* tempdb encrypted */
IF (
    SELECT is_encrypted
    FROM sys.databases
    WHERE name = 'tempdb'
    )  = 1

    INSERT #Results
    SELECT
        3
        , 351
        , 3
		, 'tempdb encrypted'
        , 'The tempdb database is currently encrypted.'
	    , 'tempdb'
	    , 'The tempdb database is automatically encrypted when any user database has Transparent Data Encryption (TDE) enabled.'
	    , 'This isn''t necessarily a problem, but encryption can potentially impact performance.'
	    , 'https://straightpathsql.com/ct/tempdb-encrypted';


/* Instance online over 180 days */
    IF (
        SELECT create_date 
        FROM sys.databases 
        WHERE database_id = 2
        ) < (
        SELECT DATEADD(dd, -180, CURRENT_TIMESTAMP)
        )

    INSERT #Results
    SELECT
        6
        , 603
        , 3
		, 'Instance online over 180 days'
        , 'Over 180 days since last SQL Server restart.'
	    , NULL
	    , 'Your SQL Server instance hasn''t been restarted since ' + CONVERT(VARCHAR(20), create_date, 101) + '. You are probably missing some important updates.'
	    , 'Schedule a time to update your SQL Server instance, and maybe the operating system as well.'
	    , 'https://straightpathsql.com/ct/instance-uptime'
    FROM sys.databases
    WHERE database_id = 2;

/* tempdb files on the C drive */
    INSERT #Results
    SELECT
        6
        , 604
        , 1
		, 'tempdb files on the C drive'
        , 'The file ' + [name] + ' is on the C drive.'
		, 'tempdb'
		, 'One poorly written query can cause all space on the C drive to be used, which could cause the operating system to freeze.'
		, 'When possible, create tempdb files on drives other than the C drive.'
		, 'https://straightpathsql.com/ct/tempdb-files-on-c-drive'
    FROM tempdb.sys.database_files
    WHERE [Physical_Name] LIKE 'C:\%'
	    AND (SELECT COUNT(DISTINCT SUBSTRING ([Physical_Name], 1, 1)) FROM tempdb.sys.database_files) > 1;

/* tempdb files with no growth allowed */
	IF EXISTS (
        SELECT *
        FROM tempdb.sys.database_files
        WHERE [growth] = 0
        )

        INSERT #Results
        SELECT
            6
            , 605
            , 2
			, 'tempdb file with no growth allowed'
            , 'The file ' + [name] + ' is not allowed to grow beyond its current size'
			, 'tempdb'
			, 'If you need more space than the current file size, your transactions may freeze or fail.'
			, 'Review the current file size and usage to see if you want to allow for growth.'
			, 'https://straightpathsql.com/ct/tempdb-no-growth-allowed'
        FROM tempdb.sys.database_files
		WHERE [growth] = 0;


/* tempdb files with max size set */
    INSERT #Results
    SELECT
        6
        , 619
        , 1
        , 'tempdb file with max size set'
        , 'The file ' + [name] + ' is not allowed to grow beyond ' + CONVERT(NVARCHAR(50), [max_size]/128) + ' MB.'
        , 'tempdb'
        , 'If this file grows to the max size, your transactions may freeze or fail.'
        , 'If tempdb files are isolated on their own drive(s), change the file growth settings to allow for unlimited growth.'
        , 'https://straightpathsql.com/ct/tempdb-max-file-size'
    FROM tempdb.sys.database_files
    WHERE [growth] > 0
        AND [max_size] NOT IN (0, -1);


/* Number of data files not recommended */
    IF @NumberOfCPUCores < 8 
    
            INSERT #Results
            SELECT
                7
                , 707
                , 1
				, 'Number of tempdb data files not recommended'
                , 'There are ' + CONVERT(VARCHAR(3), @NumberOfDataFiles) + ' tempdb data files on a server with ' + CONVERT(VARCHAR(3), @NumberOfCPUCores) + ' CPU cores.'
    			, 'tempdb'
    			, 'Microsoft recommends having the same number of data files as CPU cores (up to 8) to reduce file contention.'
    			, 'Configure tempdb to have ' + CONVERT(VARCHAR(3), @NumberOfCPUCores) + ' evenly sized data files.'
    			, 'https://straightpathsql.com/ct/tempdb-data-file-count'
            WHERE @NumberOfDataFiles <> @NumberOfCPUCores;
    
    IF @NumberOfCPUCores >= 8 
    
            INSERT #Results
            SELECT
                7
				, 707
                , 1
				, 'Number of tempdb data files not recommended'
                , 'There are ' + CONVERT(VARCHAR(3), @NumberOfDataFiles) + ' tempdb data files on a server with ' + CONVERT(VARCHAR(3), @NumberOfCPUCores) + ' CPU cores.'
    			, 'tempdb'
    			, 'Microsoft recommends having the same number of data files as CPU cores (up to 8) to reduce file contention.'
    			, 'If this configuration was not intentional, configure tempdb to have 8 evenly sized data files.'
    			, 'https://straightpathsql.com/ct/tempdb-data-file-count'
            WHERE @NumberOfDataFiles <> 8;

/* Unevenly sized data files */
	IF (
        SELECT COUNT(DISTINCT([size]))
        FROM tempdb.sys.database_files
        WHERE [type] = 0
        ) > 1

        INSERT #Results
        SELECT
            7
			, 708
            , 1
			, 'Unequally sized tempdb data files'
            , 'tempdb has unequally sized data files'
			, 'tempdb'
			, 'Unequally sized data files result in an uneven distribution of usage among the data files.'
			, 'Make sure all tempdb data files are sized equally and have the same growth settings.'
			, 'https://straightpathsql.com/ct/tempdb-data-file-size';

/* Uneven growth settings */
	IF (
    SELECT COUNT(DISTINCT CAST(growth AS VARCHAR(20)) + '_' + CAST(is_percent_growth AS CHAR(1)))
    FROM tempdb.sys.database_files
    WHERE [type] = 0
        ) > 1

        INSERT #Results
        SELECT
            7
			, 709
            , 1
			, 'Uneven tempdb growth rates'
            , 'tempdb data files have uneven growth rates'
			, 'tempdb'
			, 'Uneven growth rates result in uneven sized data files, which result in an uneven distribution of usage among the data files.'
			, 'Make sure all tempdb data files are sized equally and have the same growth settings.'
			, 'https://straightpathsql.com/ct/tempdb-data-file-growth';

/* Log file larger than data files */
     IF (
         SELECT SUM(CAST([size] AS BIGINT))
         FROM sys.master_files
         WHERE [database_id] = 2
         AND [type] = 1
         ) > (
         SELECT SUM(CAST([size] AS BIGINT))
         FROM sys.master_files
         WHERE [database_id] = 2
         AND [type] = 0
		 )

        INSERT #Results
        SELECT
            7
			, 710
            , 2
			, 'tempdb log file larger than data files'
            , 'tempdb has a log file larger than the data file'
			, 'tempdb'
			, 'This may indicate you have or had a very large transaction.'
			, 'Use a tool like sp_WhoIsActive to make sure you don''t have any runaway transactions in tempdb.'
			, 'https://straightpathsql.com/ct/tempdb-log-file-size';


/* Files with percentage growth rates */
	IF EXISTS (
        SELECT *
        FROM tempdb.sys.database_files
        WHERE [is_percent_growth] = 1
        )

        INSERT #Results
        SELECT
            7
			, 711
            , 1
			, 'tempdb file with percentage growth rates'
            , 'The file ' + [name] + ' has a percentage growth rate'
			, 'tempdb'
			, 'Percentage growth rates will lead to a high number of growth events.'
			, 'This can lead to slow performance during growths, so we recommend using a fixed growth rate of 64 MB or greater.'
			, 'https://straightpathsql.com/ct/tempdb-data-file-growth'
        FROM tempdb.sys.database_files
        WHERE [is_percent_growth] = 1;

/* Files with growth rates less than 64 MB */
	IF EXISTS (
        SELECT *
        FROM tempdb.sys.database_files
        WHERE [is_percent_growth] = 0
        AND [growth] BETWEEN 1 AND 8191
        )

        INSERT #Results
        SELECT
            7
			, 712
            , 1
			, 'tempdb file with growth rates less than 64 MB'
            , 'The file ' + [name] + ' has a growth rate of only ' + CONVERT(NVARCHAR(50), [growth]/128) + ' MB'
			, 'tempdb'
			, 'Small growth rates can lead to a high number of growth events.'
			, 'Microsoft sets default growth rates of 64 MB, so we recommend that as a minimum.'
			, 'https://straightpathsql.com/ct/tempdb-data-file-growth'
        FROM tempdb.sys.database_files
        WHERE [is_percent_growth] = 0
        AND [growth] BETWEEN 1 AND 8191;

/* Multiple log files */
	IF (
        SELECT COUNT([file_id])
        FROM tempdb.sys.database_files
        WHERE [type] = 1
        ) > 1

        INSERT #Results
        SELECT
            7
			, 713
            , 1
			, 'Multiple log files'
            , 'tempdb has multiple log files'
			, 'tempdb'
			, 'You don''t need (or want) multiple log files in a SQL Server database.'
			, 'Empty and remove any extra log files.'
			, 'https://straightpathsql.com/ct/tempdb-multiple-log-files';

/* Files with high usage */
	IF EXISTS (
        SELECT *
        FROM tempdb.sys.database_files
        WHERE ((CAST(FILEPROPERTY(name, 'SpaceUsed') AS INT) * 1.)/([size]* 1.) * 100) > @UsagePercent
        )

        INSERT #Results
        SELECT
            7
			, 714
            , 1
			, 'tempdb file with high usage'
            , 'The file ' + [name] + ' has more than ' + CONVERT(VARCHAR(3), @UsagePercent) + ' percent usage.'
			, 'tempdb'
			, 'Is this amount of tempdb activity expected?'
			, 'Use @Mode = 2 to see what kinds of data is in tempdb, and what sessions are using tempdb.'
			, 'https://straightpathsql.com/ct/tempdb-files-with-high-usage'
        FROM tempdb.sys.database_files
        WHERE ((CAST(FILEPROPERTY(name, 'SpaceUsed') AS INT) * 1.)/([size]* 1.) * 100) > @UsagePercent;

/* Trace Flag 1117 and 1118 */
    IF @SQLVersionMajor < 13 BEGIN
    
        IF NOT EXISTS (SELECT * FROM #TraceFlag WHERE TraceFlag = '1117')    
                INSERT #Results
                SELECT
                    7
					, 715
                    , 2
					, 'Trace Flag 1117'
                    , 'Trace flag 1117 not enabled globally.'
        			, 'tempdb'
        			, 'For this version of SQL Server, we recommend enabling trace flag 1117 to grow all files in a filegroup at the same time.'
        			, 'Enable this trace flag in the startup parameters of the SQL Server instance.'
        			, 'https://straightpathsql.com/ct/trace-flag-1117';
    
        IF NOT EXISTS (SELECT * FROM #TraceFlag WHERE TraceFlag = '1118')    
                INSERT #Results
                SELECT
                    7
					, 716
                    , 2
					, 'Trace Flag 1118'
                    , 'Trace flag 1118 not enabled globally.'
        			, 'tempdb'
        			, 'For this version of SQL Server, we recommend enabling trace flag 1118 to reduce SGAM (allocation page) waits.'
        			, 'Enable this trace flag in the startup parameters of the SQL Server instance.'
        			, 'https://straightpathsql.com/ct/trace-flag-1118';
    
        END;

/* Memory-optimized tempdb metadata */
    IF @SQLVersionMajor >= 15 BEGIN
    
        IF (SELECT value_in_use FROM sys.configurations WHERE [name] = 'tempdb metadata memory-optimized') = 1   
                INSERT #Results
                SELECT
                    7
					, 717
                    , 2
					, 'Memory-optimized tempdb metadata'
                    , 'Memory-optimized tempdb metadata is enabled.'
        			, 'tempdb'
        			, 'This feature moves some of the most commonly used system tables in tempdb to memory-optimized tables.'
        			, 'Please be sure you meant to enable this feature.'
        			, 'https://straightpathsql.com/ct/tempdb-memory-optimized';
        END;

/* Slow reads and writes to files */
    IF OBJECT_ID('tempdb..#AvgStall') IS NOT NULL
    	DROP TABLE #AvgStall; 

    CREATE TABLE #AvgStall (
        FileId INT
        , LogicalName sysname
        , FileType NVARCHAR(60)
        , AvgReadStallMs INT
        , AvgWriteStallMs INT
		);

    INSERT #AvgStall
    SELECT
        f.[file_id]
        , f.[name]
        , f.[type_desc]
        , CAST(s.io_stall_read_ms / ( 1.0 * s.num_of_reads ) AS INT)
        , CAST(s.io_stall_write_ms / ( 1.0 * s.num_of_writes ) AS INT)
    FROM sys.dm_io_virtual_file_stats(NULL, NULL) s
    INNER JOIN sys.master_files f
        ON s.file_id = f.file_id
        AND s.database_id = f.database_id
    WHERE s.num_of_reads > 0
        AND s.num_of_writes > 0
        AND s.database_id = 2

    INSERT #Results
    SELECT
        7
		, 718
        , 1
		, 'Slow reads'
        , 'The file ' + LogicalName + ' has an average read stall time of ' + CONVERT(VARCHAR(10), AvgReadStallMs) + 'ms.'
        , 'tempdb'
        , 'This may be an indicator of issues with your I/O subsystem, or that you have queries requiring too many reads.'
        , 'Review your I/O performance and SQL Server''s wait statistics, as this may not actually be a problem.'
        , 'https://straightpathsql.com/ct/tempdb-slow-reads-and-writes'
    FROM #AvgStall
    WHERE AvgReadStallMs > @AvgReadStallMs;

    INSERT #Results
    SELECT
        7
		, 719
        , 1
		, 'Slow writes'
        , 'The file ' + LogicalName + ' has an average write stall time of ' + CONVERT(VARCHAR(10), AvgWriteStallMs) + 'ms.'
        , 'tempdb'
        , 'This may be an indicator of issues with your I/O subsystem, or that you have queries requiring too many writes.'
        , 'Review your I/O performance and SQL Server''s wait statistics, as this may not actually be a problem.'
        , 'https://straightpathsql.com/ct/tempdb-slow-reads-and-writes'
    FROM #AvgStall
    WHERE AvgWriteStallMs > @AvgWriteStallMs;
	
	SELECT
	    CASE CategoryID
            WHEN 6 THEN 'Reliability'
		    WHEN 7 THEN 'Performance'
		END AS Category
        , CASE [Importance]
            WHEN 1 THEN 'High'
		    WHEN 2 THEN 'Medium'
			ELSE 'Low'
		END AS [Importance]
        , CheckName
        , Issue
        , DatabaseName
        , Details
        , ActionStep
        , ReadMoreURL
    FROM #Results
    ORDER BY
        [Importance]
		, Category
		, CheckName;

    END;

GO
