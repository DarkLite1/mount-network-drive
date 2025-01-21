#Requires -Modules Pester
#Requires -Version 5.1

BeforeAll {
    $realCmdLet = @{
        OutFile = Get-Command Out-File
    }

    $testInputFile = @{
        Mount = @(
            @{
                Drive = @{
                    Letter = 'Z:'
                    Path   = '\\10.10.10.1\Documents'
                }
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
                'Drive'
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
            It 'Mount.Drive.<_> not found' -ForEach @(
                'Letter', 'Path'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Mount[0].Drive.$_ = $null

                & $realCmdLet.OutFile @testOutParams -InputObject (
                    $testNewInputFile | ConvertTo-Json -Depth 7
                )

                .$testScript @testParams

                Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                    $InputObject -like "*$ImportFile*Property 'Mount.Drive.$_' not found*"
                }
            }
            Context 'Mount.Credential' {
                It 'Mount.Credential.Password is missing when Mount.Credential.UserName is used' {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Mount[0].Credential = @{
                        UserName = 'Bob'
                        Password = $null
                    }

                    & $realCmdLet.OutFile @testOutParams -InputObject (
                        $testNewInputFile | ConvertTo-Json -Depth 7
                    )

                    .$testScript @testParams

                    Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                        $InputObject -like "*ERROR*Property 'Mount.Credential.Password' not found for 'Mount.Credential.UserName' with value 'Bob'*"
                    }
                }
            }
            Context 'Mount.Drive.Letter' {
                It 'Mount.Drive.Letter is already in use by a non network drive' {
                    Mock Get-WmiObject {
                        @{
                            VolumeName = 'CD Rom'
                            DeviceID   = $testInputFile.Mount[0].Drive.Letter
                            DriveType  = 5
                        }
                    }

                    & $realCmdLet.OutFile @testOutParams -InputObject (
                        $testInputFile | ConvertTo-Json -Depth 7
                    )

                    .$testScript @testParams

                    Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                        $InputObject -like "*Drive letter '$($testInputFile.Mount[0].Drive.Letter)' is already in use by drive 'CD Rom' of DriveType '5'. This is not a network drive*"
                    }
                }
                It 'Mount.Drive.Letter is not unique' {
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
                        $InputObject -like "*Property 'Mount.Drive.Letter' with value '$($testInputFile.Mount[0].Drive.Letter)' is not unique. Each drive letter needs to be unique*"
                    }
                }
                It 'Mount.Drive.Letter is missing semicolon' {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Mount = @(
                        @{
                            Drive        = @{
                                Letter = 'Z'
                                Path = $testInputFile.Mount[0].Drive.Path
                            }
                        }
                    )

                    & $realCmdLet.OutFile @testOutParams -InputObject (
                        $testNewInputFile | ConvertTo-Json -Depth 7
                    )

                    .$testScript @testParams

                    Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                        $InputObject -like "*Property 'Mount.Drive.Letter' with value 'Z' is not a valid drive letter. Drive letter needs to be in the format 'X:'*"
                    }
                }
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
            ($Name -eq $testInputFile.Mount[0].Drive.Letter.TrimEnd(':')) -and
            ($Root -eq $testInputFile.Mount[0].Drive.Path) -and
            ($PSProvider -eq 'FileSystem') -and
            ($Scope -eq 'Global') -and
            ($Persist -eq $true)
        }
    }
    It 'create log file' {
        Should -Invoke Out-File -Exactly 1 -Scope Describe -ParameterFilter {
            $InputObject -like "*Mount drive '$($testInputFile.Mount[0].Drive.Letter)' to '$($testInputFile.Mount[0].Drive.Path)'*"
        }
    }
}
Describe 'when the drive is mounted' {
    BeforeAll {
        Mock Get-WmiObject {
            @{
                VolumeName   = 'SharedDrive'
                DeviceID     = $testInputFile.Mount[0].Drive.Letter
                DriveType    = 4
                ProviderName = $testInputFile.Mount[0].Drive.Path
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
Describe 'use credential to mount the drive when mount.credential is used' {
    It 'call New-PSDrive with Credential' {
        Mock Get-WmiObject

        $testNewInputFile = Copy-ObjectHC $testInputFile
        $testNewInputFile.Mount[0].Credential = @{
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