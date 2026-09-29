#requires -Modules Pester
BeforeAll {
    Import-Module ($Global:BrownserveRepoPowerShellYAMLPath | Convert-Path) -Force -Verbose:$false

    $ExcludedDirectories = @('.git', '.tmp', 'packages', 'paket-files', 'node_modules')
    $WorkflowsDirectory = Join-Path $Global:BrownserveRepoRootDirectory -ChildPath '.github' -AdditionalChildPath 'workflows'

    function Read-Workflow
    {
        param
        (
            [System.IO.FileInfo]
            $File
        )
        $Yaml = ConvertFrom-Yaml (Get-Content -Path $File.FullName -Raw)
        $Uses = @()
        $Steps = @()
        foreach ($Job in $Yaml.jobs.GetEnumerator())
        {
            if ($Job.Value.uses)
            {
                $Uses += [pscustomobject]@{ Workflow = $File.Name; Job = $Job.Key; Uses = $Job.Value.uses }
            }
            foreach ($Step in @($Job.Value.steps))
            {
                if ($Step.uses)
                {
                    $Uses += [pscustomobject]@{ Workflow = $File.Name; Job = $Job.Key; Uses = $Step.uses }
                }
                if ($Step.name)
                {
                    $Steps += [pscustomobject]@{ Workflow = $File.Name; Job = $Job.Key; Name = $Step.name; Step = $Step }
                }
            }
        }
        [pscustomobject]@{ Uses = $Uses; Steps = $Steps }
    }

    function ConvertTo-SortedObject
    {
        param
        (
            $InputObject
        )
        if ($InputObject -is [System.Collections.IDictionary])
        {
            $Sorted = [ordered]@{}
            foreach ($Key in ($InputObject.Keys | Sort-Object))
            {
                $Sorted[$Key] = ConvertTo-SortedObject $InputObject[$Key]
            }
            return $Sorted
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string])
        {
            return , @($InputObject | ForEach-Object { ConvertTo-SortedObject $_ })
        }
        return $InputObject
    }

    function Get-ComparableStep
    {
        param
        (
            [System.Collections.IDictionary]
            $Step
        )
        $Comparable = @{}
        foreach ($Key in $Step.Keys)
        {
            if ($Key -ne 'env')
            {
                $Comparable[$Key] = $Step[$Key]
            }
        }
        if ($Comparable.uses -like 'actions/checkout@*' -and $Comparable.with)
        {
            $With = @{}
            foreach ($Key in $Comparable.with.Keys)
            {
                if ($Key -notin @('fetch-depth', 'token'))
                {
                    $With[$Key] = $Comparable.with[$Key]
                }
            }
            if ($With.Count -gt 0)
            {
                $Comparable.with = $With
            }
            else
            {
                $Comparable.Remove('with')
            }
        }
        ConvertTo-SortedObject $Comparable
    }

    function ConvertTo-StepJson
    {
        param
        (
            $Value
        )
        ConvertTo-Json -InputObject $Value -Depth 10 -Compress
    }

    $WorkflowFiles = Get-ChildItem -Path $WorkflowsDirectory -File | Where-Object { $_.Extension -in @('.yaml', '.yml') }
    $script:AllWorkflows = $WorkflowFiles | ForEach-Object { Read-Workflow $_ }
    $script:AllUses = @($script:AllWorkflows.Uses)
    $script:SharedWorkflows = $WorkflowFiles |
        Where-Object { $_.Name -like 'brownserve-*.yaml' } |
        ForEach-Object { Read-Workflow $_ }
    $script:SharedSteps = @($script:SharedWorkflows.Steps)
    $script:ActionFiles = Get-ChildItem -Path $Global:BrownserveRepoRootDirectory -Recurse -File -Force |
        Where-Object {
            $RelativePath = [System.IO.Path]::GetRelativePath($Global:BrownserveRepoRootDirectory, $_.FullName).Replace('\', '/')
            $_.Name -in @('action.yml', 'action.yaml') -and
            !(($RelativePath -split '/') | Where-Object { $_ -in $ExcludedDirectories })
        }
}

Describe 'reusable workflows' {
    It 'are found' {
        $script:SharedWorkflows | Should -Not -BeNullOrEmpty
        $script:SharedSteps | Should -Not -BeNullOrEmpty
    }

    It 'do not reference this repository or use local paths' {
        $Failures = $script:AllUses |
            Where-Object { $_.Uses -like 'Brownserve-UK/actions*' -or $_.Uses.StartsWith('./') } |
            ForEach-Object { "$($_.Workflow) ($($_.Job)) uses '$($_.Uses)'" }
        @($Failures).Count | Should -Be 0 -Because "workflows must not reference this repository's own actions or workflows:`n$($Failures -join "`n")"
    }

    It 'are not accompanied by any composite actions' {
        $Failures = $script:ActionFiles | ForEach-Object {
            [System.IO.Path]::GetRelativePath($Global:BrownserveRepoRootDirectory, $_.FullName).Replace('\', '/')
        }
        @($Failures).Count | Should -Be 0 -Because "this repository must not contain action.yml/action.yaml files:`n$($Failures -join "`n")"
    }

    It 'keep steps with the same name identical' {
        $Failures = @()
        foreach ($Group in ($script:SharedSteps | Group-Object -Property Name))
        {
            $Locations = @($Group.Group | Select-Object -Property Workflow, Job -Unique)
            if ($Locations.Count -lt 2)
            {
                continue
            }
            $Reference = $Group.Group[0]
            $ReferenceStep = Get-ComparableStep $Reference.Step
            foreach ($Other in ($Group.Group | Select-Object -Skip 1))
            {
                if ($Other.Workflow -eq $Reference.Workflow -and $Other.Job -eq $Reference.Job)
                {
                    continue
                }
                $OtherStep = Get-ComparableStep $Other.Step
                $Differences = @(@($ReferenceStep.Keys) + @($OtherStep.Keys) | Sort-Object -Unique | Where-Object {
                        (ConvertTo-StepJson $ReferenceStep[$_]) -ne (ConvertTo-StepJson $OtherStep[$_])
                    } | ForEach-Object {
                        "'$_' is $(ConvertTo-StepJson $ReferenceStep[$_]) in $($Reference.Workflow) ($($Reference.Job)) but $(ConvertTo-StepJson $OtherStep[$_]) in $($Other.Workflow) ($($Other.Job))"
                    })
                if ($Differences.Count -gt 0)
                {
                    $Failures += "Step '$($Group.Name)' differs between $($Reference.Workflow) ($($Reference.Job)) and $($Other.Workflow) ($($Other.Job)): $($Differences -join '; ')"
                }
            }
        }
        @($Failures).Count | Should -Be 0 -Because "steps that appear in more than one job must be identical (ignoring env):`n$($Failures -join "`n")"
    }

    It 'pin each third-party action to the same ref everywhere' {
        $Failures = @()
        $ThirdParty = $script:AllUses | Where-Object { $_.Uses -notlike './*' -and $_.Uses -notlike 'docker://*' }
        foreach ($Group in ($ThirdParty | Group-Object -Property { ($_.Uses -split '@')[0] }))
        {
            $Refs = @($Group.Group | ForEach-Object { ($_.Uses -split '@', 2)[1] } | Sort-Object -Unique)
            if ($Refs.Count -gt 1)
            {
                $Usage = $Group.Group | ForEach-Object { "$($_.Workflow) ($($_.Job)) uses '$($_.Uses)'" }
                $Failures += "'$($Group.Name)' is pinned to different refs: $($Usage -join '; ')"
            }
        }
        @($Failures).Count | Should -Be 0 -Because "third-party actions must use one ref everywhere:`n$($Failures -join "`n")"
    }
}
