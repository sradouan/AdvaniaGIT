﻿$VMAdmin = Get-NAVPasswordStateUser -PasswordId $DeploymentSettings.NavServerPid
$VMCredential = New-Object System.Management.Automation.PSCredential($VMAdmin.UserName, (ConvertTo-SecureString $VMAdmin.Password -AsPlainText -Force))

Write-Host "Connecting to $($DeploymentSettings.instanceServer)..."
$Session = New-NAVRemoteSession -Credential $VMCredential -HostName $DeploymentSettings.instanceServer

Invoke-Command -Session $Session -ScriptBlock {
    param([string]$databaseToUpgrade,[string]$databaseBackupPath)

    Load-InstanceAdminTools -SetupParameters $SetupParameters
    $BackupFile = (Get-ChildItem -Path $databaseBackupPath -Filter '*.bak')[0]
    if (Test-Path -Path $BackupFile.FullName) {
        
        $result = Get-SQLCommandResult -Server localhost -Database master -Command "select database_id from sys.databases where name = '${databaseToUpgrade}'"
        if (![String]::IsNullOrEmpty($result.database_id)) {
            Write-Host "Removing Existing Database..."
            Get-SQLCommandResult -Server localhost -Database master -Command "ALTER DATABASE [${databaseToUpgrade}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${databaseToUpgrade}]" | Out-Null
        }
        Write-Host "Starting Database Restore for $($BackupFile.FullName)..."
        Get-SQLCommandResult -Server localhost -Database master -Command "RESTORE DATABASE [${databaseToUpgrade}] FROM DISK = N'$($BackupFile.FullName)' WITH FILE = 1, NOUNLOAD" -CommandTimeout 0 | Out-Null
        $command = "SELECT count(*) as [Exists] FROM sys.database_principals where (type='S' or type = 'U') and name = 'NT AUTHORITY\NETWORK SERVICE'"
        $result = Get-SQLCommandResult -Server localhost -Database $databaseToUpgrade -Command $command | Out-Null
        if ($result.Exists -eq 0) {
            Write-Host "Adding Service User..."            
            $command = "CREATE USER [NT AUTHORITY\NETWORK SERVICE] FOR LOGIN [NT AUTHORITY\NETWORK SERVICE] WITH DEFAULT_SCHEMA=[dbo]"
            $result = Get-SQLCommandResult -Server localhost -Database $databaseToUpgrade -Command $command -ErrorAction SilentlyContinue
            $command = "ALTER ROLE [db_owner] ADD MEMBER [NT AUTHORITY\NETWORK SERVICE]" 
            $result = Get-SQLCommandResult -Server localhost -Database $databaseToUpgrade -Command $command -ErrorAction SilentlyContinue
        }
        $command = "UPDATE [dbo].[`$ndo`$dbproperty] SET [license] = null"
        $result = Get-SQLCommandResult -Server localhost -Database $databaseToUpgrade -Command $command | Out-Null
    } else {
        Write-Host "Database backup not found.  Aborting!"
        exit(1)
    }

    UnLoad-InstanceAdminTools

} -ArgumentList ($DeploymentSettings.databaseToUpgrade, $DeploymentSettings.databaseBackupPath)


$Session | Remove-PSSession


