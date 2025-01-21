
<#
    .SYNOPSIS
        Mount a network drive on the local client.

    .DESCRIPTION
        This script is intended to run as a scheduled task that will be
        triggered to run every 5 minutes. The script will check every 5
        minutes if a network drive is still mounted, if it is not, it will
        mount the drive again.

        In case a drive is no longer mounted, the script will log all actions
        to a log file in the log folder.

    .PARAMETER ImportFile
        A .JSON file that contains all the parameters used by the script.

    .PARAMETER Mount.Drive.Letter
        Drive letter to mount the drive.

    .PARAMETER Mount.Drive.Path
        Network path to the folder.

    .PARAMETER Mount.Credential.UserName
        User name used to mount the drive.

        When UserName is blank, the drive is mounted under the current user,
        without extra authentication.

    .PARAMETER Mount.Credential.Password
        Password used to mount the drive.

        When Password starts with the string 'ENV:', the password is retrieved
        from the environment variables. When the 'ENV:' prefix is not there, it
        is assumed the password is in plain text in the ImportFile.

    .PARAMETER LogFolder
        Path to the log folder

    .EXAMPLE
        . 'Mount network drive\Mount network drive.ps1' -DriveLetter 'T:' -SmbSharePath '\\10.10.1.1\documents'
#>

[CmdLetBinding()]
Param (
    [parameter(Mandatory)]
    [String]$ImportFile,
    [String]$ScriptName = 'Mount network drive',
    [String]$LogFolder = "$PSScriptRoot\Log"
)

Begin {
    $ErrorActionPreference = 'Stop'

    $date = Get-Date

    $logFileMessages = @()

    Function Get-SecurePasswordHC {
        Param(
            [parameter(Mandatory)]
            [String]$Name
        )

        try {
            $plainPassword = $Name

            if ($name.StartsWith('ENV:')) {
                Write-Verbose "Retrieve environment variable '$Name'"

                $plainPassword = [Environment]::GetEnvironmentVariable(
                    $Name.Substring(4)
                )

                if (-not $plainPassword) {
                    throw "No environment variable found with name '$($Name.Substring(4))'"
                }
            }

            Write-Verbose 'Convert password to secure string'

            $params = @{
                String      = $plainPassword
                AsPlainText = $true
                Force       = $true
                ErrorAction = 'Stop'
            }
            ConvertTo-SecureString @params
        }
        catch {
            throw "Failed to get the password '$Name': $_"
        }
    }

    Function Test-isDriveMountedHC {
        [CmdLetBinding()]
        Param (
            [parameter(Mandatory)]
            [String]$DriveLetter,
            [parameter(Mandatory)]
            [String]$NetworkPath,
            $Drive
        )

        try {
            if (-not $Drive) {
                return @{
                    isMounted = $false
                    reason    = "No logical disk found with drive letter '$DriveLetter'"
                }
            }

            if ($Drive.ProviderName -ne $NetworkPath) {
                return @{
                    isMounted = $false
                    reason    = "Logical disk ProviderName '$($Drive.ProviderName)' does not match NetworkPath '$NetworkPath'"
                }
            }

            if (-not (Test-Path $DriveLetter)) {
                return @{
                    isMounted = $false
                    reason    = "Drive letter '$DriveLetter' does not exist"
                }
            }

            if (-not (Test-Path $NetworkPath)) {
                return @{
                    isMounted = $false
                    reason    = "Network path '$NetworkPath' does not exist"
                }
            }

            return @{
                isMounted = $true
            }
        }
        catch {
            throw "Failed testing if drive is mounted: $_"
        }
    }

    #region Create log folder
    try {
        $params = @{
            Path        = $LogFolder
            ItemType    = 'Directory'
            Force       = $true
            ErrorAction = 'Stop'
        }
        $logFolderItem = New-Item @params

        $logFilePath = '{0}\{1} - {2} - log.txt' -f
        $logFolderItem.FullName,
        $((Get-Date).ToString('yyyyMMdd HHmmss')),
        $ScriptName

        Write-Verbose "log file path '$logFilePath'"
    }
    Catch {
        throw "Failed creating the log folder '$LogFolder': $_"
    }
    #endregion

    $outFileParams = @{
        FilePath = $logFilePath
        Append   = $true
    }

    try {
        #region Import .json file
        try {
            $M = "Import .json file '$ImportFile'"
            Write-Verbose $M; $logFileMessages += $M

            $params = @{
                LiteralPath = $ImportFile
                Raw         = $true
                Encoding    = 'UTF8'
            }
            $jsonFileContent = Get-Content @params | ConvertFrom-Json
        }
        catch {
            throw "Failed to import file '$ImportFile': $_"
        }
        #endregion

        $Mounts = $jsonFileContent.Mount

        #region Test .json file properties
        Write-Verbose 'Test .json file properties'

        try {
            #region Missing properties
            @(
                'Mount'
            ).where(
                { -not $jsonFileContent.$_ }
            ).foreach(
                { throw "Property '$_' not found" }
            )

            foreach ($mount in $Mounts) {
                @(
                    'Drive'
                ).where(
                    { -not $mount.$_ }
                ).foreach(
                    { throw "Property 'Mount.$_' not found" }
                )

                @(
                    'Letter', 'Path'
                ).where(
                    { -not $mount.Drive.$_ }
                ).foreach(
                    { throw "Property 'Mount.Drive.$_' not found" }
                )
            }
            #endregion

            #region Test DriveLetter unique
            $Mounts.Drive.Letter | Group-Object | Where-Object {
                $_.Count -gt 1
            } | ForEach-Object {
                throw "Property 'Mount.Drive.Letter' with value '$($_.Name)' is not unique. Each drive letter needs to be unique."
            }
            #endregion

            #region Test Drive.Letter format
            $Mounts.Drive.Letter | ForEach-Object {
                if (-not ($_ -match '^[A-Z]:$')) {
                    throw "Property 'Mount.Drive.Letter' with value '$_' is not a valid drive letter. Drive letter needs to be in the format 'X:'"
                }
            }
            #endregion

            #region Test Mount.Credential.Password
            $Mounts.Credential | Where-Object {
                ($_.UserName) -and (-not ($_.Password))
            } | ForEach-Object {
                throw "Property 'Mount.Credential.Password' not found for 'Mount.Credential.UserName' with value '$($_.UserName)'. If you do not want to use authentication, leave 'Mount.Credential.UserName' blank."
            }
            #endregion
        }
        catch {
            throw "Input file '$ImportFile': $_"
        }
        #endregion

        #region Get credential
        foreach ($mount in $Mounts) {
            $userName = $mount.Credential.UserName

            $mount | Add-Member -NotePropertyMembers @{
                CredentialObject = $null
            }

            if ($userName) {
                $password = $mount.Credential.Password
                $securePassword = Get-SecurePasswordHC -Name $password

                Write-Verbose 'Create secure credential object'

                $params = @{
                    TypeName     = 'System.Management.Automation.PSCredential'
                    ArgumentList = $userName, $securePassword
                }
                $mount.CredentialObject = New-Object @params
            }
        }
        #endregion
    }
    catch {
        $M = "ERROR: $_"
        Write-Warning $M; $logFileMessages += $M
        Out-File @outFileParams -InputObject $logFileMessages
        exit
    }
}

Process {
    foreach ($mount in $Mounts) {
        try {
            $logFileMessages = @()

            $driveLetter = $mount.Drive.Letter
            $networkPath = $mount.Drive.Path
            $credential = $mount.CredentialObject

            #region Test if drive is mounted
            $drive = Get-WmiObject -Class 'Win32_LogicalDisk' | Where-Object {
                $_.DeviceID -eq $driveLetter
            }

            if ($drive -and ($drive.DriveType -ne 4)) {
                throw "Drive letter '$driveLetter' is already in use by drive '$($drive.VolumeName)' of DriveType '$($drive.DriveType)'. This is not a network drive."
            }

            Write-Verbose 'Test drive mounted'

            $params = @{
                Drive        = $drive
                DriveLetter  = $driveLetter
                NetworkPath = $networkPath
            }
            $isDriveMounted = Test-isDriveMountedHC @params
            #endregion

            if ($isDriveMounted.isMounted) {
                Write-Verbose "Drive '$driveLetter' is mounted"
                Continue
            }

            #region Verbose drive not mounted
            $M = 'Drive not mounted'
            Write-Verbose $M; $logFileMessages += $M

            $M = $isDriveMounted.reason
            Write-Verbose $M; $logFileMessages += $M
            #endregion

            #region Remove existing drive mapping
            if ($drive) {
                try {
                    $M = 'Remove existing drive'
                    Write-Verbose $M; $logFileMessages += $M

                    $params = @{
                        Name  = $driveLetter.TrimEnd(':')
                        Scope = 'Global'
                        Force = $true
                    }
                    Remove-PSDrive @params
                }
                catch {
                    throw "Failed to remove mounted drive '$driveLetter': $_"
                }
            }
            #endregion

            #region Mount drive
            try {
                $M = "Mount drive '$driveLetter' to '$networkPath'"
                Write-Verbose $M; $logFileMessages += $M

                $params = @{
                    Name       = $driveLetter.TrimEnd(':')
                    PSProvider = 'FileSystem'
                    Scope      = 'Global'
                    Root       = $networkPath
                    Persist    = $true
                }

                if ($credential) {
                    $params.Credential = $credential
                }

                New-PSDrive @params
            }
            catch {
                throw "Failed to mount drive '$driveLetter': $_"
            }
            #endregion

            #region Test drive mounted
            $M = 'Test drive mounted'
            Write-Verbose $M; $logFileMessages += $M

            $drive = Get-WmiObject -Class 'Win32_LogicalDisk' |
            Where-Object { $_.DeviceID -eq $driveLetter }

            $params = @{
                Drive        = $drive
                DriveLetter  = $driveLetter
                NetworkPath = $networkPath
            }
            $isDriveMounted = Test-isDriveMountedHC @params

            if ($isDriveMounted.isMounted) {
                $M = 'Drive mounted'
                Write-Verbose $M; $logFileMessages += $M
            }
            else {
                throw "Failed to mount drive: $($isDriveMounted.reason)"
            }
            #endregion
        }
        catch {
            $M = "ERROR: $_"; Write-Warning $M; $logFileMessages += $M
        }
        finally {
            #region Create log file
            if ($logFileMessages) {
                Write-Verbose 'Create log file'

                $header = @(
                    '', "$('_' * 15)  $ScriptName $('_' * 15) ", '',
                    "- DateTime     : '$(($date).ToString('dd/MM/yyyy HH:mm:ss'))'",
                    "- ImportFile   : '$ImportFile'",
                    "- ScriptFile   : '$PSCommandPath'",
                    "- DriveLetter  : '$driveLetter'",
                    "- NetworkPath : '$networkPath'",
                    $('_' * 52), ''
                )

                Out-File @outFileParams -InputObject (
                    $header + $logFileMessages
                )
            }
            #endregion
        }
    }
}