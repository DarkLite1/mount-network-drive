
<#
    .SYNOPSIS
        Mount a network drive on the local client.

    .DESCRIPTION
        This script is intended to run as a scheduled task that will run every
        x minutes. When a drive is no longer mapped an attempt is made to map
        the drive again.

        When a drive is mapped again or fails to map, a log file is created.

    .PARAMETER ImportFile
        A .JSON file that contains all the parameters used by the script.

    .PARAMETER DriveLetter
        The letter to use for mapping the drive.

    .PARAMETER SmbSharePath
        Network path to the folder to map.

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

    $logFileMessages = @()

    Function Test-isDriveMountedHC {
        [CmdLetBinding()]
        Param (
            [parameter(Mandatory)]
            [String]$DriveLetter,
            [parameter(Mandatory)]
            [String]$SmbSharePath,
            $Drive
        )

        try {
            Write-Verbose 'Test if drive is mounted'

            if (-not $Drive) {
                return @{
                    isMounted = $false
                    reason    = "No logical disk found with drive letter '$DriveLetter'"
                }
            }

            if ($Drive.ProviderName -ne $SmbSharePath) {
                return @{
                    isMounted = $false
                    reason    = "Logical disk ProviderName '$($Drive.ProviderName)' does not match SmbSharePath '$SmbSharePath'"
                }
            }

            if (-not (Test-Path $DriveLetter)) {
                return @{
                    isMounted = $false
                    reason    = "Drive letter '$DriveLetter' does not exist"
                }
            }

            if (-not (Test-Path $SmbSharePath)) {
                return @{
                    isMounted = $false
                    reason    = "Network path '$SmbSharePath' does not exist"
                }
            }

            $true
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

        #region Test .json file properties
        Write-Verbose 'Test .json file properties'

        try {
            @(
                'Mount'
            ).where(
                { -not $jsonFileContent.$_ }
            ).foreach(
                { throw "Property '$_' not found" }
            )

            $Mounts = $jsonFileContent.Mount

            foreach ($mount in $Mounts) {
                @(
                    'DriveLetter', 'SmbSharePath'
                ).where(
                    { -not $mount.$_ }
                ).foreach(
                    { throw "Property 'Mount.$_' not found" }
                )
            }

            #region Test unique DriveLetter
            $Mounts.DriveLetter | Group-Object | Where-Object {
                $_.Count -gt 1
            } | ForEach-Object {
                throw "Property 'Mount.DriveLetter' with value '$($_.Name)' is not unique. Each drive letter needs to be unique."
            }
            #endregion
        }
        catch {
            throw "Input file '$ImportFile': $_"
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

            $drive = Get-WmiObject -Class 'Win32_LogicalDisk' | Where-Object {
                $_.DeviceID -eq $mount.DriveLetter
            }

            if ($drive -and ($drive.DriveType -ne 4)) {
                throw "Drive letter '$($mount.DriveLetter)' is already in use by drive '$($drive.Name)' of DriveType '$($drive.DriveType)'. This is not a network drive."
            }

            $params = @{
                Drive        = $drive
                DriveLetter  = $mount.DriveLetter
                SmbSharePath = $mount.SmbSharePath
            }
            $isDriveMounted = Test-isDriveMountedHC @params

            if ($isDriveMounted.isMounted) {
                Write-Verbose "Drive '$($mount.DriveLetter)' is mounted"
                Continue
            }

            #region Verbose
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

                    Remove-PSDrive -Name $DriveLetter.TrimEnd(':') -Force
                }
                catch {
                    throw "Failed to remove mounted drive '$DriveLetter': $_"
                }
            }
            #endregion

            #region Mount drive
            try {
                $M = "Mount drive '$DriveLetter' to '$SmbSharePath'"
                Write-Verbose $M; $logFileMessages += $M

                $params = @{
                    Name       = $DriveLetter.TrimEnd(':')
                    PSProvider = 'FileSystem'
                    Scope      = 'Global'
                    Root       = $SmbSharePath
                    Persist    = $true
                }
                New-PSDrive @params
            }
            catch {
                throw "Failed to map drive '$DriveLetter': $_"
            }
            #endregion

            #region Test drive mounted
            $M = 'Test drive mounted'
            Write-Verbose $M; $logFileMessages += $M

            $drive = Get-WmiObject -Class 'Win32_LogicalDisk' |
            Where-Object { $_.DeviceID -eq $DriveLetter }

            $isDriveMounted = Test-isDriveMountedHC -Drive $drive

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
                    $('-' * 30),
                    "- DriveLetter  : '$($mount.DriveLetter)'",
                    "- SmbSharePath : '$($mount.SmbSharePath)'",
                    $('-' * 30)
                )

                Out-File @outFileParams -InputObject (
                    $header + $logFileMessages
                )
            }
            #endregion
        }
    }
}