Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Initialize-PrivateSigningDirectory {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$RequireEmpty, [switch]$AllowDpapiOnly)

    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'OutputDirectory must be an absolute path.' }
    $directory = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($directory -eq [IO.Path]::GetPathRoot($directory).TrimEnd('\')) {
        throw 'A drive root cannot be used for private signing material.'
    }
    $sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
    if ($directory.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $directory.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Private signing material must be kept outside the mac-app source directory.'
    }
    $current = $directory
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            throw 'Private signing material cannot be written inside a Git checkout.'
        }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Signing directories cannot pass through symbolic links or junctions.'
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
    if ((Test-Path -LiteralPath $directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw 'OutputDirectory is not a directory.'
    }
    if ($RequireEmpty -and (Test-Path -LiteralPath $directory) -and
        @(Get-ChildItem -LiteralPath $directory -Force).Count -ne 0) {
        throw 'OutputDirectory must be empty when creating a new signing request.'
    }
    [void][IO.Directory]::CreateDirectory($directory)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($user)
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($identity in @($user, $system)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity, [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    $aclApplied = $false
    try {
        Set-Acl -LiteralPath $directory -AclObject $acl
        $applied = Get-Acl -LiteralPath $directory
        $allowedSids = @($user.Value, $system.Value)
        $rules = @($applied.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $aclApplied = $applied.AreAccessRulesProtected -and $rules.Count -eq 2 -and
            @($rules | Where-Object {
                $_.IsInherited -or $_.IdentityReference.Value -notin $allowedSids -or
                $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl
            }).Count -eq 0
    } catch {
        if (-not $AllowDpapiOnly) {
            throw 'Windows could not apply the required private directory ACL. No signing material will be written.'
        }
    }
    if (-not $aclApplied) {
        if (-not $AllowDpapiOnly) {
            throw 'Windows did not apply the required private directory ACL. No signing material will be written.'
        }
        Write-Warning 'Directory ACL restriction is unavailable. Using the explicitly requested CurrentUser DPAPI-only storage mode; no plaintext private key or password is written.'
    }
    return $directory
}

function Write-NewSigningFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][byte[]]$Bytes)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Clear-SigningBytes {
    param([AllowNull()][byte[]]$Bytes)
    if ($null -ne $Bytes) { [Array]::Clear($Bytes, 0, $Bytes.Length) }
}

function Get-SigningEntropy {
    return ,([Text.Encoding]::UTF8.GetBytes('AnalizHukuk.MacSigning.v1'))
}

function Protect-SigningBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ,([Security.Cryptography.ProtectedData]::Protect(
        $Bytes, (Get-SigningEntropy), [Security.Cryptography.DataProtectionScope]::CurrentUser))
}

function Unprotect-SigningBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ,([Security.Cryptography.ProtectedData]::Unprotect(
        $Bytes, (Get-SigningEntropy), [Security.Cryptography.DataProtectionScope]::CurrentUser))
}
