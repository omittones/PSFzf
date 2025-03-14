
$script:GitKeyHandlers = @()

$script:foundGit = $false
$script:bashPath = $null
$script:grepPath = $null

if ($PSVersionTable.PSEdition -eq 'Core') {
    $script:pwshExec = "pwsh"
}
else {
    $script:pwshExec = "powershell"
}

function Get-GitFzfArguments() {
    # take from https://github.com/junegunn/fzf-git.sh/blob/f72ebd823152fa1e9b000b96b71dd28717bc0293/fzf-git.sh#L89
    return @{
        Ansi          = $true
        Layout        = "reverse"
        Multi         = $true
        Height        = '50%'
        MinHeight     = 20
        Border        = $true
        Color         = 'header:italic:underline'
        PreviewWindow = 'right,50%,border-left'
        Bind          = @('ctrl-/:change-preview-window(down,50%,border-top|hidden|)')
    }
}

function SetupGitPaths() {
    if (-not $script:foundGit) {
        if ($IsLinux -or $IsMacOS) {
            # TODO: not tested on Mac
            $script:foundGit = $null -ne $(Get-Command git -ErrorAction Ignore)
            $script:bashPath = 'bash'
            $script:grepPath = 'grep'
        }
        else {
            $gitInfo = Get-Command git.exe -ErrorAction Ignore
            $script:foundGit = $null -ne $gitInfo
            if ($script:foundGit) {
                # Detect if scoop is installed
                $script:scoopInfo = Get-Command scoop -ErrorAction Ignore
                if ($null -ne $script:scoopInfo) {
                    # Detect if git is installed using scoop (using shims)
                    if ((Split-Path $gitInfo.Source -Parent) -eq (Split-Path $script:scoopInfo.Source -Parent)) {
                        # Get the proper git position relative to scoop shims" position
                        $gitInfo = Get-Command "$($gitInfo.Source)\..\..\apps\git\current\bin\git.exe"
                    }
                }
                $gitPathLong = Split-Path (Split-Path $gitInfo.Source -Parent) -Parent
                # hack to get short path:
                $a = New-Object -ComObject Scripting.FileSystemObject
                $f = $a.GetFolder($gitPathLong)
                $script:bashPath = Join-Path $f.ShortPath "bin\bash.exe"
                $script:bashPath = Resolve-Path $script:bashPath
                $script:grepPath = Join-Path ${gitPathLong} "usr\bin\grep.exe"
            }
        }
    }
    return $script:foundGit
}

function SetGitKeyBindings($enable) {
    if ($enable) {
        if (-not $(SetupGitPaths)) {
            Write-Error "Failed to register git key bindings - git executable not found"
            return
        }

        if (Get-Command Set-PSReadLineKeyHandler -ErrorAction Ignore) {
            @('ctrl+g,ctrl+b', 'Select Git branches via fzf', { Update-CmdLine $(Invoke-PsFzfGitBranches) }), `
            @('ctrl+g,ctrl+f', 'Select Git files via fzf', { Update-CmdLine $(Invoke-PsFzfGitFiles) }), `
            @('ctrl+g,ctrl+h', 'Select Git hashes via fzf', { Update-CmdLine $(Invoke-PsFzfGitHashes) }), `
            @('ctrl+g,ctrl+p', 'Select Git pull requests via fzf', { Update-CmdLine $(Invoke-PsFzfGitPulLRequests) }), `
            @('ctrl+g,ctrl+s', 'Select Git stashes via fzf', { Update-CmdLine $(Invoke-PsFzfGitStashes) }), `
            @('ctrl+g,ctrl+t', 'Select Git tags via fzf', { Update-CmdLine $(Invoke-PsFzfGitTags) }) `
            | ForEach-Object {
                $script:GitKeyHandlers += $_[0]
                Set-PSReadLineKeyHandler -Chord $_[0] -Description $_[1] -ScriptBlock $_[2]
            }
        }
        else {
            Write-Error "Failed to register git key bindings - PSReadLine module not loaded"
            return
        }
    }
}

function RemoveGitKeyBindings() {
    $script:GitKeyHandlers | ForEach-Object {
        Remove-PSReadLineKeyHandler -Chord $_
    }
}

function IsInGitRepo() {
    git rev-parse HEAD 2>&1 | Out-Null
    return $?
}

function Get-ColorAlways($setting = ' --color=always') {
    if ($RunningInWindowsTerminal -or -not $IsWindowsCheck) {
        return $setting
    }
    else {
        return ''
    }
}

function Get-HeaderStrings() {
    $header = "CTRL-A (Select all) / CTRL-D (Deselect all) / CTRL-T (Toggle all)"
    $keyBinds = 'ctrl-a:select-all,ctrl-d:deselect-all,ctrl-t:toggle-all'
    return $Header, $keyBinds
}

function Update-CmdLine($result) {
    InvokePromptHack
    if ($result.Length -gt 0) {
        $result = $result -join " "
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert($result)
    }
}
function Invoke-PsFzfGitFiles() {
    if (-not (IsInGitRepo)) {
        return
    }

    if (-not $(SetupGitPaths)) {
        Write-Error "git executable could not be found"
        return
    }

    $previewCmd = "${script:bashPath} \""" + $(Join-Path $PsScriptRoot 'helpers/PsFzfGitFiles-Preview.sh') + "\"" {-1}" + $(Get-ColorAlways) + " \""$($pwd.ProviderPath)\"""
    $result = @()

    $headerStrings = Get-HeaderStrings
    $gitCmdsHeader = "`nALT-S (Git add) / ALT-R (Git reset)"
    $headerStr = $headerStrings[0] + $gitCmdsHeader + "`n`n"
    $statusCmd = "git $(Get-ColorAlways '-c color.status=always') status --short"

    $reloadBindCmd = "reload($statusCmd)"
    $stageScriptPath = Join-Path $PsScriptRoot 'helpers/PsFzfGitFiles-GitAdd.sh'
    $gitStageBind = "alt-s:execute-silent(" + """${script:bashPath}"" '${stageScriptPath}' {+2..})+down+${reloadBindCmd}"
    $resetScriptPath = Join-Path $PsScriptRoot 'helpers/PsFzfGitFiles-GitReset.sh'
    $gitResetBind = "alt-r:execute-silent(" + """${script:bashPath}"" '${resetScriptPath}' {+2..})+down+${reloadBindCmd}"

    $fzfArguments = Get-GitFzfArguments
    $fzfArguments['Bind'] += $headerStrings[1], $gitStageBind, $gitResetBind
    Invoke-Expression "& $statusCmd" | `
        Invoke-Fzf @fzfArguments `
        -BorderLabel '📁 Files' `
        -Preview "$previewCmd" -Header $headerStr | `
        foreach-object {
        $result += $_.Substring('?? '.Length)
    }

    $result
}
function Invoke-PsFzfGitHashes() {
    if (-not (IsInGitRepo)) {
        return
    }

    if (-not $(SetupGitPaths)) {
        Write-Error "git executable could not be found"
        return
    }

    $previewCmd = "${script:bashPath} \""" + $(Join-Path $PsScriptRoot 'helpers/PsFzfGitHashes-Preview.sh') + "\"" {}" + $(Get-ColorAlways) + " \""$pwd\"""
    $result = @()

    $fzfArguments = Get-GitFzfArguments
    & git log --date=short --format="%C(green)%C(bold)%cd %C(auto)%h%d %s (%an)" $(Get-ColorAlways).Trim() --graph | `
        Invoke-Fzf @fzfArguments -NoSort  `
        -BorderLabel '🍡 Hashes' `
        -Preview "$previewCmd" | ForEach-Object {
        if ($_ -match '\d\d-\d\d-\d\d\s+([a-f0-9]+)\s+') {
            $result += $Matches.1
        }
    }

    $result
}

function Invoke-PsFzfGitBranches() {
    if (-not (IsInGitRepo)) {
        return
    }

    if (-not $(SetupGitPaths)) {
        Write-Error "git executable could not be found"
        return
    }

    $fzfArguments = Get-GitFzfArguments
    $fzfArguments['PreviewWindow'] = 'down,border-top,40%'
    $gitBranchesHelperPath = Join-Path $PsScriptRoot 'helpers/PsFzfGitBranches.sh'
    $ShortcutBranchesAll = "ctrl-a:change-prompt(🌳 All branches> )+reload(" + """${script:bashPath}"" '${gitBranchesHelperPath}' all-branches)"
    $fzfArguments['Bind'] += 'ctrl-/:change-preview-window(down,70%|hidden|)', $ShortcutBranchesAll

    $previewCmd = "${script:bashPath} \""" + $(Join-Path $PsScriptRoot 'helpers/PsFzfGitBranches-Preview.sh') + "\"" {}"
    $result = @()
    # use pwsh to prevent bash from trying to write to host output:
    $branches = & $script:pwshExec -NoProfile -NonInteractive -Command "&  ${script:bashPath} '$gitBranchesHelperPath' branches"
    $branches |
    Invoke-Fzf @fzfArguments -Preview "$previewCmd" -BorderLabel '🌲 Branches' -HeaderLines 2 -Tiebreak begin -ReverseInput | `
        ForEach-Object {
        $result += $($_.Substring('* '.Length) -split ' ')[0]
    }

    $result
}

function Invoke-PsFzfGitTags() {
    if (-not (IsInGitRepo)) {
        return
    }

    if (-not $(SetupGitPaths)) {
        Write-Error "git executable could not be found"
        return
    }

    $fzfArguments = Get-GitFzfArguments
    $fzfArguments['PreviewWindow'] = 'right,70%'
    $previewCmd = "git show --color=always {}"
    $result = @()
    git tag --sort -version:refname |
    Invoke-Fzf @fzfArguments -Preview "$previewCmd" -BorderLabel '📛 Tags' | `
        ForEach-Object {
        $result += $_
    }

    $result
}

function Invoke-PsFzfGitStashes() {
    if (-not (IsInGitRepo)) {
        return
    }

    if (-not $(SetupGitPaths)) {
        Write-Error "git executable could not be found"
        return
    }

    $fzfArguments = Get-GitFzfArguments
    $fzfArguments['Bind'] += 'ctrl-x:execute-silent(git stash drop {1})+reload(git stash list)'
    $header = "CTRL-X (drop stash)`n`n"
    $previewCmd = 'git show --color=always {1}'

    $result = @()
    git stash list --color=always |
    Invoke-Fzf @fzfArguments -Header $header -Delimiter ':' -Preview "$previewCmd" -BorderLabel '🥡 Stashes' | `
        ForEach-Object {
        $result += $_.Split(':')[0]
    }

    $result
}

function Invoke-PsFzfGitPullRequests() {
    if (-not (IsInGitRepo)) {
        return
    }

    if (-not $(SetupGitPaths)) {
        Write-Error "git executable could not be found"
        return
    }
    # find the repo remote URL
    $remoteUrl = git config --get remote.origin.url

    # GitHub
    if ($remoteUrl -match 'github.com') {
        $script:ghCmdInfo = Get-Command gh -ErrorAction Ignore
        if ($null -ne $script:ghCmdInfo) {
            $listAllPrsCmdJson = Invoke-Expression "gh pr list --json id,author,title,number"
            $objs = $listAllPrsCmdJson | ConvertFrom-Json | ForEach-Object {
                [PSCustomObject]@{
                    PR      = "$($PSStyle.Foreground.Green)" + $_.number
                    Title   = "$($PSStyle.Foreground.Magenta)" + $_.title
                    Creator = "$($PSStyle.Foreground.Yellow)" + $_.author.login
                }
            }
        }
        else {
            Write-Error "Repo is a GitHub repo and gh command not found"
            return
        }
        $webCmd = 'gh pr view {1} --web'
        $previewCmd = 'gh pr view {1} && gh pr diff {1}'
    }
    # Azure DevOps
    elseif ($remoteUrl -match 'dev.azure.com|visualstudio.com') {
        $script:azCmdInfo = Get-Command az -ErrorAction Ignore
        if ($null -ne $script:azCmdInfo) {
            $listAllPrsCmdJson = Invoke-Expression 'az repos pr list --status "active" --query "[].{title: title, number: pullRequestId, creator: createdBy.uniqueName}"'
            $objs = $listAllPrsCmdJson | ConvertFrom-Json | ForEach-Object {
                [PSCustomObject]@{
                    PR      = "$($PSStyle.Foreground.Green)" + $_.number
                    Title   = "$($PSStyle.Foreground.Magenta)" + $_.title
                    Creator = "$($PSStyle.Foreground.Yellow)" + $_.creator
                }
            }
        }
        else {
            Write-Error "Repo is an Azure DevOps repo and az command not found"
            return
        }
        $webCmd = 'az repos pr show --id {1} --open --output none'
        # currently errors on query. Need to fix instead of output everything
        #$previewCmd = 'az repos pr show --id {1} --query "{Created:creationDate, Closed:closedDate, Creator:createdBy.displayName, PR:codeReviewId, Title:title, Repo:repository.name, Reviewers:join('', '',reviewers[].displayName), Source:sourceRefName, Target:targetRefName}" --output yamlc'
        $previewCmd = 'az repos pr show --id {1} --output yamlc'
    }

    $fzfArguments = Get-GitFzfArguments
    $fzfArguments['Bind'] += 'ctrl-o:execute-silent(' + $webCmd + ')'
    $header = "CTRL-O (open in browser)`n`n"

    $prevCLICOLOR_FORCE = $env:CLICOLOR_FORCE
    $prevOutputRendering = $PSStyle.OutputRendering

    $env:CLICOLOR_FORCE = 1 # make gh show keep colors
    $PSStyle.OutputRendering = 'Ansi'

    try {
        $result = @()
        $objs | out-string -Stream  | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | `
            Invoke-Fzf @fzfArguments -Header $header -Preview "$previewCmd" -HeaderLines 2 -BorderLabel '🆕 Pull Requests' | `
            ForEach-Object {
            $result += $_.Split(' ')[0] # get the PR ID
        }
    }
    finally {
        $env:CLICOLOR_FORCE = $prevCLICOLOR_FORCE
        $PSStyle.OutputRendering = $prevOutputRendering
    }

    $result
}
