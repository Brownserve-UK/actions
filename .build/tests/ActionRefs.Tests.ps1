#requires -Modules Pester
BeforeAll {
    $ExcludedDirectories = @('.git', '.tmp', 'packages', 'paket-files', 'node_modules')
    $ReferencePattern = 'Brownserve-UK/actions/([^@''"\s]+)@(v\d+\.\d+\.\d+)'
    $script:References = Get-ChildItem -Path $Global:BrownserveRepoRootDirectory -Recurse -File -Force |
        ForEach-Object {
            $RelativePath = [System.IO.Path]::GetRelativePath($Global:BrownserveRepoRootDirectory, $_.FullName).Replace('\', '/')
            if (($RelativePath -split '/')[0] -notin $ExcludedDirectories)
            {
                $Content = Get-Content -Path $_.FullName -Raw -ErrorAction 'SilentlyContinue'
                if ($Content)
                {
                    [regex]::Matches($Content, $ReferencePattern) |
                        ForEach-Object { [pscustomobject]@{ Path = $RelativePath; Version = $_.Groups[2].Value } }
                }
            }
        }
}

Describe 'internal action/workflow references' {
    It 'are found in the reusable workflows' {
        $script:References | Where-Object { $_.Path -like '.github/workflows/*' } | Should -Not -BeNullOrEmpty
    }

    It 'all point at the same version' {
        $UniqueVersions = @($script:References.Version | Sort-Object -Unique)
        $UniqueVersions.Count | Should -Be 1 -Because "every 'Brownserve-UK/actions/...@vX.Y.Z' reference should point at the same version, found: $($UniqueVersions -join ', ')"
    }
}
