Install-Module DBATools

$sqlSubId = 'yourSubIdHere'
$miSubId = 'yourSubIdHere'

# Login on Azure Subscription
Add-AzAccount

# Deploy a SQL optimized VM in the Azure location
$RgName = 'MI-Demo-RG'
$Rg = Get-AzResourceGroup -Name $RgName -Location "westeurope" -ErrorAction SilentlyContinue
if(!$Rg) {
    $Rg = New-AzResourceGroup -Name $RgName -Location "westeurope"
}

New-AzResourceGroupDeployment -ResourceGroupName $Rg.ResourceGroupName `
    -TemplateUri "https://raw.githubusercontent.com/OmegaMadLab/OptimizedSqlVm/master/azuredeploy.json" `
    -TemplateParameterFile ".\template_param.json" `
    -Name "MIDEMOSQL" `
    -AsJob

## Establish a peering between SQL2012 vnet and Managed Instance vnet - May be not needed, depending on the environment
$sqlVnetId = "/subscriptions/$sqlSubId/resourceGroups/MI-Demo-RG/providers/Microsoft.Network/virtualNetworks/SQL-Demo-Vnet"
$miVnetId = "/subscriptions/$miSubId/resourceGroups/AzureSQLMI-Demo-RG/providers/Microsoft.Network/virtualNetworks/SQLMI-Demo-Vnet"

# Peer sqlVnet to miVnet.
$localVnet = Get-AzResource -ResourceId $sqlVnetId | Get-AzureRmVirtualNetwork 
Add-AzureRmVirtualNetworkPeering `
  -Name 'SQL-2-MI' `
  -VirtualNetwork $localVnet `
  -RemoteVirtualNetworkId $miVnetId

# Peer miVnet to sqlVnet - Switch subscription context to MI sub
Select-AzSubscription -SubscriptionId $miSubId
$localVnet = Get-AzResource -ResourceId $miVnetId | Get-AzureRmVirtualNetwork 
Add-AzureRmVirtualNetworkPeering `
  -Name 'MI-2-SQL' `
  -VirtualNetwork $localVnet `
  -RemoteVirtualNetworkId $sqlVnetId

## Deploy a SQL DB to be used with linked server -- For reference purpose, not used in demo
# $sqlAdminCreds = Get-Credential
# # Create server
# $dbServer = New-AzSqlServer -ServerName OmegaMadLabDemo `
#     -SqlAdministratorCredentials $sqlAdminCreds `
#     -Location 'West Europe' `
#     -ResourceGroupName $RgName

# # Add a firewall rule for client current public IP Address
# # Thanks to Chrissy LeMaire :)
# # https://gallery.technet.microsoft.com/scriptcenter/Get-ExternalPublic-IP-c1b601bb
# $clientIp = Invoke-RestMethod http://ipinfo.io/json | Select -exp ip
# New-AzSqlServerFirewallRule -FirewallRuleName "ClientIp" `
#     -StartIpAddress $clientIp `
#     -EndIpAddress $clientIp `
#     -ServerName $dbServer.ServerName `
#     -ResourceGroupName $RgName

# # Add a firewall rule for SQLONPREM VM current public IP Address
# $pipId = (Get-AzResource -ResourceId (Get-AzVm -Name "SQLONPREM" -ResourceGroupName $RgName).NetworkProfile.NetworkInterfaces.id | 
#     Get-AzNetworkInterface |
#     Get-AzNetworkInterfaceIpConfig).PublicIpAddress.Id
# $vmPublicIp = Get-AzResource -ResourceId $pipId | Get-AzPublicIpAddress | Select -ExpandProperty IpAddress
# New-AzSqlServerFirewallRule -FirewallRuleName "SqlVmIp" `
#     -StartIpAddress $vmPublicIp `
#     -EndIpAddress $vmPublicIp `
#     -ServerName $dbServer.ServerName `
#     -ResourceGroupName $RgName

# New-AzSqlDatabase -DatabaseName RemoteDB `
#     -ServerName $dbServer.ServerName `
#     -SampleName AdventureWorksLT `
#     -Edition Basic `
#     -ResourceGroupName $RgName

# # Create a contained db user for Linked Server on SQL VM
# $sqlStmt = @"
# CREATE USER [dbadmin] 
# WITH PASSWORD = 'Passw0rd', 
# DEFAULT_SCHEMA = dbo; 

# ALTER ROLE db_owner ADD MEMBER [dbadmin]; 
# "@
    
# Invoke-DbaQuery -SqlInstance $dbServer.FullyQualifiedDomainName `
#     -SqlCredential $sqlAdminCreds `
#     -Database RemoteDB `
#     -Query $sqlStmt

## Prepare a storage account for SQL Backups demo.
# Since we're using SQL2012 for demo, we'll use account name and account keys for credential creation inside SQL VM
$storageAccount = New-AzStorageAccount -Name "sqldemobackup$(-join ((1..9) | Get-Random -Count 8))" `
                    -ResourceGroupName $RgName `
                    -Location "West Europe" `
                    -SkuName Standard_LRS
        
$accountKeys = Get-AzStorageAccountKey -Name $storageAccount.StorageAccountName `
                    -ResourceGroupName $RgName

$storageContext = New-AzStorageContext -StorageAccountName $storageAccount.StorageAccountName `
                    -StorageAccountKey $accountKeys[0].Value

$container = New-AzStorageContainer -Context $storageContext `
                -Name "sqlbackup"
                
Write-Host "Save the following storage account parameters; they will be used inside SQL VM to create credential for backup to storage account." -ForegroundColor Green
Write-Host "Storage account name:`t$($storageAccount.StorageAccountName)"
Write-Host "Storage account Key1:`t$($accountKeys[0].Value)"

## Deploy a MI on its vnet - MI Sub
# Switch subscription
Select-AzSubscription -SubscriptionId $miSubId

# Get parameters needed for MI creation
$miRgName = "ManagedInstance-Demo-RG"
$miVnet = Get-AzVirtualNetwork -Name "DemoVnet" `
            -ResourceGroupName $miRgName
$miSubnet = $miVnet | Get-AzVirtualNetworkSubnetConfig -Name "SqlMiSubnet"

$sqlAdminCreds = Get-Credential -Message "Insert new credentials for Managed Instance admin:"

# Create MI
New-AzSqlInstance -Name "omegamadlabdemomi" `
    -ResourceGroupName $miRgName `
    -Location 'West Europe' `
    -SubnetId $miSubnet.Id `
    -LicenseType LicenseIncluded `
    -StorageSizeInGB 32 `
    -VCore 8 `
    -SkuName GP_Gen4 `
    -AdministratorCredential $sqlAdminCreds

# Switch back to SQL VM subscription
Select-AzSubscription -SubscriptionId $sqlSubId