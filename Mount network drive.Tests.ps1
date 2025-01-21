#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $realCmdLet = @{
        OutFile = Get-Command Out-File
    }

    $testInputFile = @{
        Mount = @(
            @{
                DriveLetter  = 'Z:'
                SmbSharePath = '\\10.10.10.1\Documents'
            }
        )
    }

    $testOutParams = @{
        FilePath = (New-Item "TestDrive:/Test.json" -ItemType File).FullName
    }

    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        ImportFile = $testOutParams.FilePath
        ScriptName = 'Test'
        LogFolder  = 'TestDrive:/log'
    }

    Mock New-PSDrive
    Mock Out-File
}

Describe 'the mandatory parameters are' {
    It '<_>' -ForEach @('ImportFile') {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory |
        Should -BeTrue
    }
}
Describe 'when the script is executed' {
    It 'create the log folder' {
        .$testScript @testParams

        $testParams.LogFolder | Should -Exist
    }
}
Describe 'create a log file with an error line when' {
    Context 'the ImportFile' {
        It 'is not found' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.ImportFile = 'nonExisting.json'

            .$testScript @testNewParams

            Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                $InputObject -like "*Cannot find Path*nonExisting.json*"
            }
        }
        Context 'property' {
            It '<_> not found' -ForEach @(
                'Mount'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.$_ = $null

                & $realCmdLet.OutFile @testOutParams -InputObject (
                    $testNewInputFile | ConvertTo-Json -Depth 7
                )

                .$testScript @testParams

                Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                    $InputObject -like "*$ImportFile*Property '$_' not found*"
                }
            }
            It 'Mount.<_> not found' -ForEach @(
                'DriveLetter', 'SmbSharePath'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Mount[0].$_ = $null

                & $realCmdLet.OutFile @testOutParams -InputObject (
                    $testNewInputFile | ConvertTo-Json -Depth 7
                )

                .$testScript @testParams

                Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                    $InputObject -like "*$ImportFile*Property 'Mount.$_' not found*"
                }
            }
            Context 'Credential' {
                It 'Credential.Password is missing when Credential.UserName is used' {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Credential = @{
                        UserName = 'Bob'
                        Password = $null
                    }

                    & $realCmdLet.OutFile @testOutParams -InputObject (
                        $testNewInputFile | ConvertTo-Json -Depth 7
                    )

                    .$testScript @testParams

                    Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                        $InputObject -like "*ERROR*Property 'Credential.Password' not found for 'Credential.UserName' with value 'Bob'*"
                    }
                }
            }
            Context 'DriveLetter' {
                It 'DriveLetter is already in use by a non network drive' {
                    Mock Get-WmiObject {
                        @{
                            VolumeName = 'CD Rom'
                            DeviceID   = $testInputFile.Mount[0].DriveLetter
                            DriveType  = 5
                        }
                    }

                    & $realCmdLet.OutFile @testOutParams -InputObject (
                        $testInputFile | ConvertTo-Json -Depth 7
                    )

                    .$testScript @testParams

                    Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                        $InputObject -like "*Drive letter '$($testInputFile.Mount[0].DriveLetter)' is already in use by drive 'CD Rom' of DriveType '5'. This is not a network drive*"
                    }
                }
                It 'DriveLetter is not unique' {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Mount = @(
                        Copy-ObjectHC $testInputFile.Mount[0]
                        Copy-ObjectHC $testInputFile.Mount[0]
                    )

                    & $realCmdLet.OutFile @testOutParams -InputObject (
                        $testNewInputFile | ConvertTo-Json -Depth 7
                    )

                    .$testScript @testParams

                    Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                        $InputObject -like "*Property 'Mount.DriveLetter' with value '$($testInputFile.Mount[0].DriveLetter)' is not unique. Each drive letter needs to be unique*"
                    }
                } -Tag test
            }
        }
    }
}
Describe 'when no drive is mounted' {
    BeforeAll {
        Mock Get-WmiObject

        & $realCmdLet.OutFile @testOutParams -InputObject (
            $testInputFile | ConvertTo-Json -Depth 7
        )

        .$testScript @testParams
    }
    It 'mount the drive' {
        Should -Invoke New-PSDrive -Exactly -Times 1 -Scope Describe -ParameterFilter {
            ($Name -eq $testInputFile.Mount[0].DriveLetter.TrimEnd(':')) -and
            ($Root -eq $testInputFile.Mount[0].SmbSharePath) -and
            ($PSProvider -eq 'FileSystem') -and
            ($Scope -eq 'Global') -and
            ($Persist -eq $true)
        }
    }
    It 'create log file' {
        Should -Invoke Out-File -Exactly 1 -Scope Describe -ParameterFilter {
            $InputObject -like "*Mount drive '$($testInputFile.Mount[0].DriveLetter)' to '$($testInputFile.Mount[0].SmbSharePath)'*"
        }
    }
}
Describe 'when the drive is mounted' {
    BeforeAll {
        Mock Get-WmiObject {
            @{
                VolumeName   = 'SharedDrive'
                DeviceID     = $testInputFile.Mount[0].DriveLetter
                DriveType    = 4
                ProviderName = $testInputFile.Mount[0].SmbSharePath
            }
        }
        Mock Test-Path {
            $true
        }

        & $realCmdLet.OutFile @testOutParams -InputObject (
            $testInputFile | ConvertTo-Json -Depth 7
        )

        .$testScript @testParams
    }
    It 'do not mount the drive again' {
        Should -Not -Invoke New-PSDrive -Scope Describe
    }
    It 'do not create a log file' {
        Should -Not -Invoke Out-File -Scope Describe
    }
}
Describe 'user credentials to mount the drive when Credentials are given' {
    It 'call New-PSDrive with Credential' {
        Mock Get-WmiObject

        $testNewInputFile = Copy-ObjectHC $testInputFile
        $testNewInputFile.Credential = @{
            UserName = 'Bob'
            Password = 'testPassword'
        }

        & $realCmdLet.OutFile @testOutParams -InputObject (
            $testNewInputFile | ConvertTo-Json -Depth 7
        )

        .$testScript @testParams

        Should -Invoke New-PSDrive -Times 1 -Exactly -ParameterFilter {
            $Credential -ne $null
        }
    }
}