Install-Module DBATools, SqlServer -AllowClobber

# Download AdventureWorks2012 from GitHub and restore it on default instance
$dbBckUrl = "https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2012.bak"
New-Item "C:\Temp" -ItemType Directory -Force

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest $dbBckUrl -OutFile "C:\Temp\AdventureWorks2012.bak"

Get-Item "C:\Temp\AdventureWorks2012.bak" | Restore-DbaDatabase -SqlInstance localhost

# Install Ola Hallengren DBA Maintenance solution
New-DbaDatabase -SqlInstance localhost -Name DBAMaintenance
Install-DbaMaintenanceSolution -SqlInstance localhost `
    -Database DBAMaintenance `
    -LogToTable `
    -InstallJobs `
    -CleanupTime 48

## Create some demo sql logins
#Enable SQL Auth
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL11.MSSQLSERVER\MSSQLServer" `
    -Name LoginMode `
    -Value 2

# Create logins
New-DbaLogin -SqlInstance localhost `
    -Login "sqladmin" `
    -SecurePassword (ConvertTo-SecureString -String "Passw0rd" -AsPlainText -Force)

New-DbaLogin -SqlInstance localhost `
    -Login "dbadmin" `
    -SecurePassword (ConvertTo-SecureString -String "Passw0rd" -AsPlainText -Force)

New-DbaLogin -SqlInstance localhost `
    -Login "SqlUser01" `
    -SecurePassword (ConvertTo-SecureString -String "Pwd1!!!!!!!" -AsPlainText -Force)

New-DbaLogin -SqlInstance localhost `
    -Login "SqlUser02" `
    -SecurePassword (ConvertTo-SecureString -String "Pwd2!!!!!!!" -AsPlainText -Force)

$sqlStmt = @"
CREATE USER [SqlUser01] 
FOR LOGIN [SqlUser01] 
WITH DEFAULT_SCHEMA = dbo; 

CREATE USER [SqlUser02] 
FOR LOGIN [SqlUser02] 
WITH DEFAULT_SCHEMA = dbo; 

ALTER ROLE db_owner ADD MEMBER [SqlUser01];
ALTER ROLE db_owner ADD MEMBER [dbadmin]; 
ALTER ROLE db_datareader ADD MEMBER [SqlUser02]; 
ALTER SERVER ROLE sysadmin ADD MEMBER sqladmin; 
"@

Invoke-DbaQuery -SqlInstance localhost -Database AdventureWorks2012 -Query $sqlStmt

## Enable TDE on AdventureWorks2012
# Create a new master key
$pwd = ConvertTo-SecureString -AsPlainText -Force -String "`$tr0ngP4ssw0rd"
New-DbaDbMasterKey -SqlInstance localhost -SecurePassword $pwd
# Create a new certificate
New-DbaDbCertificate -SqlInstance localhost -Name "TDE_CERT"

$sqlStmt = @"
USE [AdventureWorks2012]
CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER CERTIFICATE TDE_CERT;
GO

ALTER DATABASE [AdventureWorks2012]
SET ENCRYPTION ON;
GO
"@

Invoke-DbaQuery -Query $sqlStmt -SqlInstance localhost

## Create a linked server to localhost for demo
$sqlStmt = @"
Execute master.dbo.sp_addlinkedserver 
        @server = 'RemoteServer'
        ,@srvproduct = N'SQLServer OLEDB Provider'
        ,@provider = N'SQLNCLI'
        ,@datasrc = '$((Get-NetIPConfiguration).IPv4Address.IpAddress)'

Execute master.dbo.sp_addlinkedsrvlogin 
        @rmtsrvname = 'RemoteServer'
        ,@useself = N'False'
        ,@locallogin = NULL 
        ,@rmtuser = N'dbadmin'              
        ,@rmtpassword = 'Passw0rd'       
"@

Invoke-DbaQuery -Query $sqlStmt -SqlInstance localhost -Database master

## Enable DBMail config
# Install a local SMTP service to be used by SQL. SMTP won't be fully configured, so it won't send emails
Install-WindowsFeature -Name smtp-server -IncludeManagementTools -IncludeAllSubFeature

# Enable DBMail, configure it for local SMTP and add a fake operator
$sqlStmt = @"
-- Enable DB Mail
EXEC sp_configure 'show advanced options', '1';
RECONFIGURE
GO
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE
GO
EXEC sp_configure 'Agent XPs', 1;
RECONFIGURE
GO

USE [msdb]
GO

-- Configure DB Mail
-- Create a Database Mail profile  
EXECUTE msdb.dbo.sysmail_add_profile_sp  
    @profile_name = 'DBANotifications',  
    @description = 'Profile used for sending outgoing notifications.' ;  

-- Grant access to the profile to the DBMailUsers role  
EXECUTE msdb.dbo.sysmail_add_principalprofile_sp  
    @profile_name = 'DBANotifications',  
    @principal_name = 'public',  
    @is_default = 1 ;

-- Create a Database Mail account  
EXECUTE msdb.dbo.sysmail_add_account_sp  
    @account_name = 'SQLDemo',  
    @description = 'Mail account for sending outgoing notifications.',  
    @email_address = 'sql@omegamadlab.demo',  
    @display_name = 'SQL Automated Mailer',  
    @mailserver_name = '{0}',
    @port = 25  

-- Add the account to the profile  
EXECUTE msdb.dbo.sysmail_add_profileaccount_sp  
    @profile_name = 'DBANotifications',  
    @account_name = 'SQLDemo',  
    @sequence_number =1 ;  
GO

-- Enable mail on SQL Agent
USE [msdb]
GO
EXEC msdb.dbo.sp_set_sqlagent_properties
                 @email_save_in_sent_folder=1,
                 @databasemail_profile=N'DBANotifications', -- put your database mail profile here
                 @use_databasemail=1
GO

-- Create operator
EXEC msdb.dbo.sp_add_operator @name=N'SQLDemo Operator', 
		@enabled=1, 
		@weekday_pager_start_time=90000, 
		@weekday_pager_end_time=180000, 
		@saturday_pager_start_time=90000, 
		@saturday_pager_end_time=180000, 
		@sunday_pager_start_time=90000, 
		@sunday_pager_end_time=180000, 
		@pager_days=0, 
		@email_address=N'sqloperator@sqlonprem', 
		@category_name=N'[Uncategorized]'
GO
"@

Invoke-DbaQuery -SqlInstance localhost `
    -Query $($sqlStmt -f (Get-NetIPConfiguration).IPv4Address.IpAddress)

## Enabling backup to URL
# Credential creation
$storageAccountName = Read-Host -Prompt "Insert storage account name"
$storageAccountKey = Read-Host -Prompt "Insert storage account key" -AsSecureString

New-DbaCredential -SqlInstance localhost `
    -Name AzureBackupBlobStore `
    -Identity $storageAccountName `
    -SecurePassword $storageAccountKey

# Create a SQL Agent Job which use Hallengren's solution to backup on Storage Account
$jobCommand = @"
EXECUTE dbo.DatabaseBackup
@Databases = 'USER_DATABASES',
@URL = 'https://$storageAccountName.blob.core.windows.net/sqlbackup',
@Credential = 'AzureBackupBlobStore',
@BackupType = 'FULL',
@Compress = 'Y'
"@

New-DbaAgentSchedule -SqlInstance localhost `
    -Schedule "daily" `
    -FrequencyType "Daily" `
    -FrequencyInterval "Everyday" `
    -Force

New-DbaAgentJob -SqlInstance localhost `
    -Job "BackupToAzureDemo" `
    -Schedule "daily" `
    -OwnerLogin sqladmin

New-DbaAgentJobStep -SqlInstance localhost `
    -Job "BackupToAzureDemo" `
    -StepName "Backup" `
    -Command $jobCommand `
    -Database "DBAMaintenance" `
    -Force

## Download and install Microsoft Data Migration Assistant
start-process iexplore "https://www.microsoft.com/en-us/download/details.aspx?id=53595"

## Download and install SSMS 18 preview
start-process iexplore "https://go.microsoft.com/fwlink/?linkid=2052501&clcid=0x409"