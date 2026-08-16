# irm https://raw.githubusercontent.com/yoshi-ortiz/harness-core/main/install.ps1 | iex
#
# Windows entry point. The harness itself (pony.harness.sh, sync-skills.sh) is
# bash, so Git Bash is required either way — this installs it with winget and
# then hands off to install.sh, which does the real work.
$ErrorActionPreference = 'Stop'

$RepoUrl = if ($env:HARNESS_REPO) { $env:HARNESS_REPO } else { 'https://github.com/yoshi-ortiz/harness-core.git' }
$RepoDir = if ($env:HARNESS_DIR)  { $env:HARNESS_DIR }  else { Join-Path $HOME '.harness-core' }

function Say($m) { Write-Host "-> $m" }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw "winget not found - install 'App Installer' from the Microsoft Store"
}

function Need($cmd, $id) {
  if (Get-Command $cmd -ErrorAction SilentlyContinue) { return }
  Say "winget install $id"
  winget install --id $id -e --source winget `
    --accept-package-agreements --accept-source-agreements
  # winget updates the registry PATH; refresh it for this process
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

Need git Git.Git

$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
  foreach ($p in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
    if (Test-Path $p) { $bash = $p; break }
  }
} else { $bash = $bash.Source }
if (-not $bash) { throw 'Git Bash not found after installing Git - reopen your shell and re-run' }

if (Test-Path (Join-Path $RepoDir '.git')) {
  Say "updating $RepoDir"
  git -C $RepoDir pull --ff-only
} else {
  Say "cloning into $RepoDir"
  git clone --depth 1 $RepoUrl $RepoDir
}

Say 'handing off to install.sh'
& $bash (Join-Path $RepoDir 'install.sh') @args
