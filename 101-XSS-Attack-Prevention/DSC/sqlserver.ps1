[CmdletBinding()]
param (
    # Resource group name
    [Parameter(Mandatory = $true)]
    [string]
    $ResourceGruopName,

    # Sql server admin user
    [Parameter(Mandatory = $true)]
    [string]
    $SqlAdminUser,

    # Sql admin user password
    [Parameter(Mandatory = $true)]
    [securestring]
    $SqlAdminPassword
)

Function Get-StringHash([String]$String, $HashName = "SHA1") {
    $StringBuilder = New-Object System.Text.StringBuilder
    [System.Security.Cryptography.HashAlgorithm]::Create($HashName).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($String))| 
        ForEach-Object { [Void]$StringBuilder.Append($_.ToString("x2"))
    }
    $StringBuilder.ToString().Substring(0, 24)
}

$clientIPAddress = Invoke-RestMethod http://ipinfo.io/json | Select-Object -exp ip
$clientIPHash = (Get-StringHash $clientIPAddress).substring(0, 5)
$databaseName = "contosoclinic"
$artifactsLocation = Split-Path($PSScriptRoot)
$dbBackpacFilePath = "$artifactsLocation/artifacts/contosoclinic.bacpac"

$deploymentResourceGroup = (Get-AzureRmResourceGroup -Name $ResourceGruopName)
$storageAccountName = "sqlinjectionstg" + (Get-StringHash ($deploymentResourceGroup.ResourceGroupName)).Substring(0,5)
$storageContainerName = "artifacts"
$artifactsStorageAccKeyType = "StorageAccessKey"

# Updating SQL server firewall rule
Write-Verbose -Message "Updating SQL server firewall rule."
$sqlServerName = (Get-AzureRmSqlServer | Where-Object ResourceGroupName -EQ $ResourceGruopName).ServerName

New-AzureRmSqlServerFirewallRule -ResourceGroupName $ResourceGruopName -ServerName $sqlServerName -FirewallRuleName "ClientIpRule$clientIPHash" -StartIpAddress $clientIPAddress -EndIpAddress $clientIPAddress -ErrorAction SilentlyContinue
New-AzureRmSqlServerFirewallRule -ResourceGroupName $ResourceGruopName -ServerName $sqlServerName -FirewallRuleName "AllowAzureServices" -StartIpAddress 0.0.0.0 -EndIpAddress 0.0.0.0 -ErrorAction SilentlyContinue

Start-Sleep -Seconds 10

Write-Verbose "Check if artifacts storage account exists."
$storageAccount = (Get-AzureRmStorageAccount -ResourceGroupName $ResourceGruopName | Where-Object {$_.StorageAccountName -eq $storageAccountName})

# Create the storage account if it doesn't already exist
if ($storageAccount -eq $null) {
    Write-Verbose "Artifacts storage account does not exists."
    Write-Verbose "Provisioning artifacts storage account."
    $storageAccount = New-AzureRmStorageAccount -StorageAccountName $storageAccountName -Type 'Standard_LRS' `
        -ResourceGroupName $ResourceGruopName -Location $deploymentResourceGroup.Location
    Write-Verbose "Artifacts storage account provisioned."
    Write-Verbose "Creating storage container to upload a blobs."
    New-AzureStorageContainer -Name $storageContainerName -Context $storageAccount.Context -ErrorAction SilentlyContinue
}
else {
    Write-Verbose "Artifact storage account aleardy exists."
    New-AzureStorageContainer -Name $storageContainerName -Context $storageAccount.Context -ErrorAction SilentlyContinue
}
Write-Verbose "Container created."
# Retrieve Access Key 
$artifactsStorageAccKey = (Get-AzureRmStorageAccountKey -Name $storageAccount.StorageAccountName -ResourceGroupName $storageAccount.ResourceGroupName)[0].value 
Write-Verbose "Connection key retrieved."

Write-Verbose -Message "uploading sql bacpac file to storage account"
Set-AzureStorageBlobContent -File $dbBackpacFilePath -Blob "artifacts/contosoclinic.bacpac" `
            -Container $storageContainerName -Context $storageAccount.Context -Force

# Import SQL bacpac and update azure SQL DB Data masking policy

Write-Verbose -Message "Importing SQL bacpac and Updating Azure SQL DB Data Masking Policy"

$artifactsLocation = $storageAccount.Context.BlobEndPoint + $storageContainerName
# Importing bacpac file
Write-Verbose -Message "Importing SQL backpac from release artifacts storage account."
$sqlBacpacUri = "$artifactsLocation/artifacts/contosoclinic.bacpac"
$importRequest = New-AzureRmSqlDatabaseImport -ResourceGroupName $ResourceGruopName -ServerName $sqlServerName -DatabaseName $databaseName -StorageKeytype $artifactsStorageAccKeyType -StorageKey $artifactsStorageAccKey -StorageUri "$sqlBacpacUri" -AdministratorLogin $SqlAdminUser -AdministratorLoginPassword $SqlAdminPassword -Edition Standard -ServiceObjectiveName S0 -DatabaseMaxSizeBytes 50000
$importStatus = Get-AzureRmSqlDatabaseImportExportStatus -OperationStatusLink $importRequest.OperationStatusLink
Write-Verbose "Importing.."
while ($importStatus.Status -eq "InProgress")
{
    $importStatus = Get-AzureRmSqlDatabaseImportExportStatus -OperationStatusLink $importRequest.OperationStatusLink
    Write-Verbose "Database import is in progress... "
    Start-Sleep -s 5
}
$importStatus

Write-Host "Deployment Completed."