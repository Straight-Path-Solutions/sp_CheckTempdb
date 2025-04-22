# sp_CheckTempdb
Hello, and welcome to the GitHub repository for sp_CheckTempdb! This is a free tool from [Straight Path Solutions](https://straightpathsql.com/) for SQL Server Database Administrators (or people who play DBA at their organization) to check their SQL Server tempdb configuration and performance. It is used to quickly detect issues as well as for immediate troubleshooting when tempdb appears to be a current point performance issues.

# Why would you use sp_CheckTempdb?

Here at Straight Path Solutions, we're big fans of community tools like [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive/releases), [Brent Ozar's First Responder's Kit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/releases), and [Erik Darling's suite of helpful stored procedures](https://github.com/erikdarlingdata/DarlingData). As database administrators who are constantly looking at new clients and new servers, we wished there was a tool to quickly give an overview of potential issues with tempdb configuration, as well as something to look in depth at current tempdb usage. We didn’t find one, so we made one.

# What does sp_CheckTempdb do?

This tool will allow you to review your SQL Server tempdb configuration quickly and easily, and to also identify potential issues with your configuration like misconfigured files, problematic settings, and read/write performance. It also lets you look at what is currently using tempdb if needed for immediate troubleshooting.<p>

This tool has several modes that present a different set of data, depending on what you want to examine.<p>

**Mode 0: A check for problems** <br>
Check for potential issues we could find related to configuration and performance.<br>
<br>
**Mode 1: A summary of tempdb files** <br>
Show the current configuration of all tempdb files, as you would see when reviewing the Properties of the Files in SSMS.<br>
<br>
**Mode 2: A detailed look at what is using tempdb now** <br>
Returns 1 summary and 2 detail results sets, showing information about the current usage of data and log files.<br>
<br>
**Mode 3: A check for tempdb contention** <br>
a check for metadata or allocation contention in tempdb.<br>
<br>
Using each of these Modes, you should be able to quickly identify performance issues with your tempdb database.

# How do I use it?
Execute the script to create sp_CheckTempdb in the database of your choice, although we would recommend the master so you can call it from the context of any database.
<p>
Executing it without using parameters will return two results sets:<p>
• The results of Mode 1, ordered by File ID<br>
• The results of Mode 0, ordered by Importance
<p>
Although you can simply execute it as is, there are several parameters you cna use.<p>

**@Help** - the default is 0, but setting this to 1 will return some helpful information about sp_CheckTempdb and its usage in case you aren't able to read this web page.<p>

**@Mode** – see the previous few paragraphs to decide which Mode you want to use.<p>

**@Size** - the default is 'MB', which will display all size values in megabytes. If you have a larger tempdb, you can set this to 'GB' to display size values in gigabytes.<p>

**@UsagePercent** - the default for this is 50, which means it will check to see if any data or log files have more than 50% usage. Use this to check for unusually high activity in tempdb, or an open transaction that is causing excessive usage of tempdb.<p>

**@AvgReadStallMs** - the default is 20, which means it will return information for any tempdb file that has an average read stall value greater than 20 milliseconds. Use this to check for excessive tempdb reads and/or possible storge issues.<p>

**@AvgWriteStallMs** - the default is 20, which means it will return information for any tempdb file that has an average write stall value greater than 20 milliseconds. Use this to check for excessive tempdb reads and/or possible storge issues.<p>

# What do the Importance levels in Mode 0 mean?

**1 - High**. This is stuff that will contribute to performance degradation, so you should try to address these issues when you can.

**2 - Medium**. This is the stuff that may or may not be intentional, like tempdb settings or trace flags. Review these findings to make sure these were all intended or expected results.

**3 - Low**. This is stuff that probably isn't a problem, but you should be aware of it anyways.

# What are the requirements to use sp_CheckTempdb?

There are two requirements.<p>

**1. You need to have VIEW SERVER STATE permissions**. This tool uses several system tables and DMVs to collect information about your SQL Server tempdb database, but VIEW SERVER STATE permissions will allow you to read all necessary information.<p>

**2. Your SQL Server instance should be using SQL Server 2014 or higher**. If you are using an earlier version, execution of the stored procedure will skip some checks because some of the DMVs used don't exist in earlier versions.<p>

