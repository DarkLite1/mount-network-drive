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
        }
    }
    It 'DriveLetter is already in use by a non network drive' {
        Mock Get-WmiObject {
            @{
                Name      = 'CD Rom'
                DeviceID  = $testInputFile.Mount[0].DriveLetter
                DriveType = 5
            }
        }

        & $realCmdLet.OutFile @testOutParams -InputObject (
            $testInputFile | ConvertTo-Json -Depth 7
        )

        .$testScript @testParams

        Should -Invoke Out-File -Exactly 1 -ParameterFilter {
            $InputObject -like "*Drive letter '$($testInputFile.Mount[0].DriveLetter)' is already in use by drive 'CD Rom' of DriveType '5'. This is not a network drive*"
        }
    } -Tag test
}
Describe 'when no drive is mounted' {
    It 'mount the drive' {
        Mock Get-WmiObject {
            @{
                Name      = 'CD Rom'
                DriveType = 5
            }
        }
    }
}