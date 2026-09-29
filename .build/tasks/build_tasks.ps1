<#
.SYNOPSIS
    This contains the build tasks for Invoke-Build to use.
    Each task is documented with a synopsis and description to explain what it does.
#>
[CmdletBinding()]
param
(
    # The branch this is being built from
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $BranchName,

    # The default branch for this repository
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $DefaultBranch,

    # The type of changes that this version contains (used to determine the version number)
    [Parameter(
        Mandatory = $false
    )]
    [ValidateSet(
        'major',
        'minor',
        'patch'
    )]
    [string]
    $ReleaseType,

    # The various places to publish to
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('GitHub')]
    [string[]]
    $PublishTo,

    # The GitHub organisation/account to publish the release to
    [Parameter(
        Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoOwner,

    # The GitHub repo name
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoName = $Global:BrownserveRepoName,

    # GitHub token used during the StageRelease build, must have the following permissions:
    #   * Read/Write pull requests
    #   * Read issues
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $GitHubStageReleaseToken,

    # GitHub token used during the Release build, must have the following permissions:
    #   * Read/write releases
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $GitHubReleaseToken
)

# Depending on how we got the branch name we may need to remove the full ref
$BranchName = $BranchName -replace 'refs\/heads\/', ''
$script:CurrentCommitHash = & git rev-parse HEAD

# Script-scoped variables populated by tasks
$script:Release = $false
$script:Stage = $false
$script:Changelog = $null
$script:CurrentVersion = $null
$script:NewVersion = $null
$script:PrefixedVersion = $null
$script:ReleaseVersion = $null
$script:ReleaseNotes = $null
$script:StagingBranchName = $null
$script:PRLink = $null
$script:TrackedFiles = @()
$script:ChangelogPath = Join-Path $Global:BrownserveRepoRootDirectory 'CHANGELOG.md'

<#
.SYNOPSIS
    Validates that all parameters required to publish a release have been provided.
#>
task CheckPublishingParameters {
    if (!$PublishTo)
    {
        throw 'PublishTo must be set when performing a release'
    }
    if ('GitHub' -in $PublishTo)
    {
        if (!$GitHubReleaseToken)
        {
            throw 'GitHubReleaseToken must be provided when publishing to GitHub'
        }
    }
}

<#
.SYNOPSIS
    Validates that all parameters required to stage a release have been provided.
#>
task CheckStagingParameters {
    if (!$GitHubStageReleaseToken)
    {
        throw 'GitHubStageReleaseToken must be set when staging a release'
    }
}

<#
.SYNOPSIS
    Sets up additional variables required for staging a release.
#>
task SetStagingVariables {
    Write-Verbose 'Setting staging variables'
    $script:Stage = $true
}

<#
.SYNOPSIS
    Sets up additional variables required for a release.
#>
task SetReleaseVariables {
    Write-Verbose 'Setting release variables'
    $script:Release = $true
}

<#
.SYNOPSIS
    Reads the changelog and extracts the version history.
#>
task GetReleaseHistory {
    Write-Build White 'Getting release history'
    $script:Changelog = Read-BrownserveChangelog `
        -ChangelogPath $script:ChangelogPath
    if ($script:Release -ne $true)
    {
        $script:CurrentVersion = ($script:Changelog.VersionHistory | Where-Object { !$_.PreRelease } | Select-Object -First 1).Version
    }
    else
    {
        $script:CurrentVersion = $script:Changelog.LatestVersion.Version
    }
    Write-Verbose "Current version: $script:CurrentVersion"
}

<#
.SYNOPSIS
    Determines the new version number based on the release type.
#>
task SetVersion GetReleaseHistory, {
    Write-Build White 'Setting version'
    if (!$ReleaseType)
    {
        throw 'ReleaseType must be set when staging or releasing'
    }
    $script:NewVersion = switch ($ReleaseType)
    {
        'major' { [semver]::new($script:CurrentVersion.Major + 1, 0, 0) }
        'minor' { [semver]::new($script:CurrentVersion.Major, $script:CurrentVersion.Minor + 1, 0) }
        'patch' { [semver]::new($script:CurrentVersion.Major, $script:CurrentVersion.Minor, $script:CurrentVersion.Patch + 1) }
    }
    $script:PrefixedVersion = "v$script:NewVersion"
    Write-Verbose "New version: $script:PrefixedVersion"
    $script:StagingBranchName = "release/$script:PrefixedVersion"
}

<#
.SYNOPSIS
    Rewrites every internal 'Brownserve-UK/actions/<path>@vX.Y.Z' reference in the repository to the new version.
.DESCRIPTION
    Scans every file under the repository (excluding ephemeral/dependency directories) for references to this
    repository's own actions/workflows and rewrites the version tag to the version being staged, so the release
    commit carries them. Files it changes are added to the set of tracked files that get committed to the
    staging branch alongside CHANGELOG.md.
#>
task UpdateActionReferences SetVersion, {
    Write-Build White 'Updating internal action/workflow references'
    $ExcludedDirectories = @('.git', '.tmp', 'packages', 'paket-files', 'node_modules')
    $ReferencePattern = 'Brownserve-UK/actions/([^@''"\s]+)@v\d+\.\d+\.\d+'
    $Files = Get-ChildItem -Path $Global:BrownserveRepoRootDirectory -Recurse -File -Force |
        Where-Object {
            $RelativePath = [System.IO.Path]::GetRelativePath($Global:BrownserveRepoRootDirectory, $_.FullName)
            ($RelativePath -split '[\\/]')[0] -notin $ExcludedDirectories
        }
    foreach ($File in $Files)
    {
        $Content = Get-Content -Path $File.FullName -Raw -ErrorAction 'SilentlyContinue'
        if ($null -eq $Content)
        {
            continue
        }
        if ($Content -notmatch $ReferencePattern)
        {
            continue
        }
        $Updated = [regex]::Replace($Content, $ReferencePattern, "Brownserve-UK/actions/`$1@$script:PrefixedVersion")
        if ($Updated -ne $Content)
        {
            Set-Content -Path $File.FullName -Value $Updated -NoNewline
            $script:TrackedFiles += ($File.FullName | Convert-Path)
            Write-Verbose "Updated references in $($File.FullName)"
        }
    }
}

<#
.SYNOPSIS
    Creates a new changelog entry for the upcoming release.
#>
task CreateChangelogEntry SetVersion, {
    if ($script:CurrentVersion -eq $script:NewVersion)
    {
        throw 'Current version and new version are the same, cannot create changelog entry'
    }
    Write-Build White "Creating new changelog entry for '$script:NewVersion'"
    $NewChangelogEntryParams = @{
        Version         = $script:NewVersion
        RepositoryOwner = $GitHubRepoOwner
        RepositoryName  = $GitHubRepoName
        ChangelogObject = $script:Changelog
        SinceVersion    = $script:CurrentVersion
    }
    if ($GitHubStageReleaseToken)
    {
        $NewChangelogEntryParams.Add('Auto', $true)
        $NewChangelogEntryParams.Add('GitHubToken', $GitHubStageReleaseToken)
    }
    else
    {
        throw 'GitHub token not provided, cannot generate release notes'
    }
    try
    {
        $script:NewReleaseNotes = New-BrownserveChangelogEntry @NewChangelogEntryParams
    }
    catch
    {
        throw "Failed to create changelog entry.`n$($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Updates the changelog with the new release notes.
#>
task UpdateChangelog CreateChangelogEntry, {
    Write-Build White 'Updating changelog'
    try
    {
        $script:Changelog | Add-BrownserveChangelogEntry `
            -NewContent $script:NewReleaseNotes `
            -ErrorAction 'Stop'
    }
    catch
    {
        throw "Failed to update changelog.`n$($_.Exception.Message)"
    }
    $script:TrackedFiles += ($script:ChangelogPath | Convert-Path)
}

<#
.SYNOPSIS
    Creates a remote staging branch via the GitHub API.
#>
task CreateStagingBranch SetVersion, {
    Write-Build White "Creating staging branch '$script:StagingBranchName'"
    try
    {
        New-GitHubBranch `
            -RepositoryOwner $GitHubRepoOwner `
            -RepositoryName  $GitHubRepoName `
            -BranchName      $script:StagingBranchName `
            -SHA             $script:CurrentCommitHash `
            -Token           $GitHubStageReleaseToken `
            -ErrorAction 'Stop'
    }
    catch
    {
        throw "Failed to create staging branch '$script:StagingBranchName'.`n$($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Commits tracked file changes (CHANGELOG.md and any files with updated internal references) to the staging branch.
#>
task CommitTrackedChanges UpdateChangelog, UpdateActionReferences, CreateStagingBranch, {
    if ($script:TrackedFiles.Count -gt 0)
    {
        Write-Build White 'Committing tracked changes'
        try
        {
            $Files = $script:TrackedFiles | ForEach-Object {
                @{
                    Path    = [System.IO.Path]::GetRelativePath($Global:BrownserveRepoRootDirectory, $_).Replace('\', '/')
                    Content = Get-Content -Path $_ -Raw
                }
            }
            New-GitHubCommit `
                -RepositoryOwner $GitHubRepoOwner `
                -RepositoryName  $GitHubRepoName `
                -BranchName      $script:StagingBranchName `
                -CommitMessage   "docs: Prepare for $script:PrefixedVersion`n`nThis commit was automatically generated." `
                -Files           $Files `
                -Token           $GitHubStageReleaseToken `
                -ErrorAction 'Stop'
        }
        catch
        {
            throw "Failed to commit tracked changes.`n$($_.Exception.Message)"
        }
    }
    else
    {
        Write-Verbose 'No tracked files to commit.'
    }
}

<#
.SYNOPSIS
    Creates a pull request for the staged release.
#>
task CreatePullRequest CommitTrackedChanges, {
    Write-Build White 'Creating pull request'
    try
    {
        $Body = @'
This PR was automatically generated.
Please review the changes and merge if they look good.
'@
        $PullRequestParams = @{
            BaseBranch      = $DefaultBranch
            HeadBranch      = $script:StagingBranchName
            Title           = "Prepare for $script:PrefixedVersion"
            Body            = $Body
            GitHubToken     = $GitHubStageReleaseToken
            RepositoryName  = $GitHubRepoName
            RepositoryOwner = $GitHubRepoOwner
        }
        $PRDetails = New-GitHubPullRequest @PullRequestParams
        $script:PRLink = $PRDetails.html_url
        Write-Debug "PRLink: $script:PRLink"
    }
    catch
    {
        throw "Failed to create pull request.`n$($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Runs actionlint against every workflow and composite action in the repository.
#>
task Lint {
    Write-Build White 'Running actionlint'
    $ActionlintPath = Join-Path $Global:BrownserveRepoBinaryDirectory ($IsWindows ? 'actionlint.exe' : 'actionlint')
    Push-Location $Global:BrownserveRepoRootDirectory
    try
    {
        exec { & $ActionlintPath }
    }
    finally
    {
        Pop-Location
    }
}

<#
.SYNOPSIS
    Runs the linter that checks every action.yml and workflow in the repository.
#>
task Build Lint, {}

<#
.SYNOPSIS
    Runs Pester tests for the repository.
#>
task Tests {
    Write-Build White 'Running Pester tests'
    $Results = Invoke-Pester -Path $Global:BrownserveRepoTestsDirectory -PassThru
    assert ($Results.FailedCount -eq 0) "$($Results.FailedCount) test(s) failed."
}

<#
.SYNOPSIS
    Lints the repository and runs Pester tests.
    Used by the CI pipeline on pull requests.
#>
task BuildTestAndCheck Build, Tests, {}

<#
.SYNOPSIS
    Creates a GitHub release for the new version. This repository publishes no release assets, the tag itself
    is what consumers pin against.
#>
task PublishRelease GetReleaseHistory, {
    Write-Build White 'Publishing release'
    $script:ReleaseVersion = $script:Changelog.LatestVersion.Version.ToString()
    $script:PrefixedVersion = "v$script:ReleaseVersion"
    $script:ReleaseNotes = $script:Changelog.LatestVersion.ReleaseNotes -join "`n"

    if ('GitHub' -in $PublishTo)
    {
        Write-Build White 'Checking for existing GitHub releases'
        $CurrentReleases = Get-GitHubRelease `
            -GitHubToken $GitHubReleaseToken `
            -RepoName    $GitHubRepoName `
            -GitHubOrg   $GitHubRepoOwner
        if ($CurrentReleases.tag_name -contains $script:PrefixedVersion)
        {
            throw "A GitHub release for $script:PrefixedVersion already exists!"
        }

        Write-Build White "Creating GitHub release $script:PrefixedVersion"
        try
        {
            New-GitHubRelease `
                -Name            $script:PrefixedVersion `
                -Tag             $script:PrefixedVersion `
                -Description     $script:ReleaseNotes `
                -GitHubToken     $GitHubReleaseToken `
                -RepositoryName  $GitHubRepoName `
                -RepositoryOwner $GitHubRepoOwner `
                -ErrorAction     'Stop' | Out-Null
        }
        catch
        {
            throw "Failed to create GitHub release.`n$($_.Exception.Message)"
        }
    }
    else
    {
        Write-Verbose 'GitHub not targeted, skipping...'
    }
}

<#
.SYNOPSIS
    Stages a release by updating the changelog, bumping internal action/workflow references and creating a pull request.
    This is the first step in a two-stage release process.
#>
task StageRelease CheckStagingParameters, SetStagingVariables, CreatePullRequest, {
    $BuildMessage = @"
The release has been successfully staged and a pull request has been created.
Please review the changes at $script:PRLink and merge if they look good.
"@
    Write-Build Green $BuildMessage
}

<#
.SYNOPSIS
    Performs all release steps except publishing to GitHub.
    Useful for verifying the release process locally without pushing anything.
#>
task DryRun SetReleaseVariables, CheckPublishingParameters, GetReleaseHistory, Build, Tests, {}

<#
.SYNOPSIS
    Publishes the release by creating a GitHub release for the new version.
    Run this after merging the pull request created by StageRelease.
#>
task Release CheckPublishingParameters, SetReleaseVariables, PublishRelease, {}
