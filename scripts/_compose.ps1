Set-StrictMode -Version Latest

function Resolve-ContainerEngine {
    param(
        [Parameter(Mandatory = $true)][string]$Engine
    )

    if ($Engine -ne "auto") {
        return $Engine
    }

    $hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
    $hasPodman = [bool](Get-Command podman -ErrorAction SilentlyContinue)

    $podmanHasCompose = $false
    if ($hasPodman) {
        try {
            & podman compose version *> $null
            if ($LASTEXITCODE -eq 0) {
                $podmanHasCompose = $true
            }
        } catch {
            # ignore and fall back
        }

        if (-not $podmanHasCompose -and (Get-Command podman-compose -ErrorAction SilentlyContinue)) {
            $podmanHasCompose = $true
        }
    }

    if ($podmanHasCompose) {
        return "podman"
    }

    if ($hasDocker) {
        return "docker"
    }

    if ($hasPodman) {
        throw "Podman is installed but no Compose frontend found. Install 'podman-compose' or a Podman 'compose' plugin."
    }

    throw "No container engine found. Install Docker Desktop or Podman Desktop, or pass -Engine docker|podman."
}

function Resolve-ComposeInvocation {
    param(
        [Parameter(Mandatory = $true)][string]$Engine
    )

    $resolvedEngine = Resolve-ContainerEngine -Engine $Engine

    if ($resolvedEngine -eq "docker") {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            throw "docker command not found."
        }
        return @{
            Exe      = "docker"
            BaseArgs = @("compose")
            Engine   = "docker"
        }
    }

    if ($resolvedEngine -eq "podman") {
        if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
            throw "podman command not found."
        }

        try {
            & podman compose version *> $null
            if ($LASTEXITCODE -eq 0) {
                return @{
                    Exe      = "podman"
                    BaseArgs = @("compose")
                    Engine   = "podman"
                }
            }
        } catch {
            # ignore and fall back
        }

        if (Get-Command podman-compose -ErrorAction SilentlyContinue) {
            return @{
                Exe      = "podman-compose"
                BaseArgs = @()
                Engine   = "podman"
            }
        }

        throw "Podman is installed but no Compose frontend found. Install 'podman-compose' or a Podman 'compose' plugin."
    }

    throw "Unsupported engine: $resolvedEngine"
}

function Invoke-Compose {
    param(
        [string]$Engine = "auto",
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    $inv = Resolve-ComposeInvocation -Engine $Engine
    $exe = $inv.Exe
    $baseArgs = $inv.BaseArgs

    $fullArgs = @()
    if ($null -ne $baseArgs -and $baseArgs.Count -gt 0) {
        $fullArgs += $baseArgs
    }
    $fullArgs += $Args

    Write-Host "Running: $exe $($fullArgs -join ' ')"
    & $exe @fullArgs
}
