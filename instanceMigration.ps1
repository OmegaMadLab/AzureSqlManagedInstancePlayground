Install-Module Az, DBATools, SQLServer -AllowClobber

$miSqlAdmin = Get-Credential -Message "Insert credential for SQL MI Admin:"
$miServerName = "omegamadlabmidemo.0eaf086f34d7.database.windows.net"
$dmsRgName = 'MI-Demo-RG'

## Prepare for DMS
# Disable UAC (https://gallery.technet.microsoft.com/scriptcenter/Disable-UAC-using-730b6ecd)
# Needed to migrate TDE Cert
$osversion = (Get-CimInstance Win32_OperatingSystem).Version 
$version = $osversion.split(".")[0] 
 
if ($version -eq 10) { 
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value "0" 
} ElseIf ($Version -eq 6) { 
    $sub = $version.split(".")[1] 
    if ($sub -eq 1 -or $sub -eq 0) { 
        Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value "0" 
    } Else { 
        Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value "0" 
    } 
} ElseIf ($Version -eq 5) { 
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value "0" 
} Else { 
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value "0" 
}

# Create a shared folder where backups are archived and retrieved by DMS.
# We're using F:\SQLBackup, which is default backup location for SQL Instance.
# We need to give full access to SQL Server service account and to local computer account
New-SmbShare -Path F:\SQLBackup `
    -Name "SQLBackup" `
    -FullAccess "NT SERVICE\MSSQLSERVER", "SQLONPREM", "SQLONPREM\localadmin"

# Prepare a storage account container to hosts SQL backup on Azure
# and generate a SAS token to access it. This token will be passed to DMS during its configuration
Login-AzAccount

$storageAccount = New-AzStorageAccount -Name "sqldemodmsbackup$(-join ((1..9) | Get-Random -Count 6))" `
                    -ResourceGroupName $dmsRgName `
                    -Location "West Europe" `
                    -SkuName Standard_LRS
        
$accountKeys = Get-AzStorageAccountKey -Name $storageAccount.StorageAccountName `
                    -ResourceGroupName $dmsRgName

$storageContext = New-AzStorageContext -StorageAccountName $storageAccount.StorageAccountName `
                    -StorageAccountKey $accountKeys[0].Value

$container = New-AzStorageContainer -Context $storageContext `
                -Name "sqldmsbackup"

$policyName = "DMS-policy"
$policy = New-AzStorageContainerStoredAccessPolicy -Container $container.Name `
            -Policy $policyName `
            -Context $storageContext `
            -StartTime $(Get-Date).ToUniversalTime().AddMinutes(-5) `
            -ExpiryTime '2050-12-31 23:59:59' `
            -Permission rwld

$sas = New-AzStorageContainerSASToken -name $container.Name `
            -Policy $policy `
            -Context $storageContext

$fullUrlSas = "$($container.CloudBlobContainer.StorageUri.PrimaryUri)$($sas)"
$fullUrlSas | clip
Write-Host "Shared Access Signature = $fullUrlSas"

### NOW IT'S TIME TO MOVE TO THE PORTAL AND CONFIGURE A MIGRATION PROJECT IN DMS

## After DMS phase
# Copy SQL Agent Config - one shot...
Copy-DbaAgentServer -Source localhost `
    -Destination $miServerName `
    -DestinationSqlCredential $miSqlAdmin `
    -Force

# ...Or copy individual items
Copy-DbaAgentSchedule -Source localhost `
    -Destination $miServerName `
    -DestinationSqlCredential $miSqlAdmin

Copy-DbaAgentJob -Source localhost `
    -Destination $miServerName `
    -DestinationSqlCredential $miSqlAdmin

Copy-DbaAgentOperator -Source localhost `
    -Destination $miServerName `
    -DestinationSqlCredential $miSqlAdmin

# Copy SQL Credential to be used for backup to URL
Copy-DbaCredential -Source localhost `
    -Destination $miServerName `
    -DestinationSqlCredential $miSqlAdmin `
    -Force

# Copy Linked Server
Copy-DbaLinkedServer -Source localhost `
    -Destination $miServerName `
    -DestinationSqlCredential $miSqlAdmin `
    -Force

# Copy DBMail
Copy-DbaDbMail -Source localhost `
    -Destination $miServerName `
    -DestinationSqlCredential $miSqlAdmin `
    -Force

# Rename DBMail default profile and enable service
$dbMailProfileId = (Get-DbaDbMailProfile -SqlInstance $miServerName `
    -SqlCredential $miSqlAdmin).Id

$sqlStmt = @"
    
EXECUTE msdb.dbo.sysmail_update_profile_sp  
    @profile_id = {0}  
    ,@profile_name = 'AzureManagedInstance_dbmail_profile'  

EXEC sp_configure 'show advanced options', 1;  
GO  
RECONFIGURE;  
GO  
EXEC sp_configure 'Database Mail XPs', 1;  
GO  
RECONFIGURE  
GO  

"@

Invoke-DbaQuery -SqlInstance $miServerName `
    -SqlCredential $miSqlAdmin `
    -Query $($sqlStmt -f $dbMailProfileId)

# CREATE A RULE FOR STMP TRAFFIC ON MI NSG!!!

