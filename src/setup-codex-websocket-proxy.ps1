#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateRange(1, 65535)]
    [int]$ProxyPort,

    [ValidateNotNullOrEmpty()]
    [string]$ProxyHost
)

$ErrorActionPreference = "Stop"
$script:SetupPhase = '配置前'

function Write-FailureLog {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        $logDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'CodexWebSocketProxy'
        [void][System.IO.Directory]::CreateDirectory($logDirectory)
        $logPath = Join-Path $logDirectory (
            'setup-error-{0}.log' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
        )
        $log = @"
时间：$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff zzz'))
阶段：$script:SetupPhase
用户：$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
PowerShell：$($PSVersionTable.PSVersion)
异常类型：$($ErrorRecord.Exception.GetType().FullName)
错误：$($ErrorRecord.Exception.Message)

$($ErrorRecord.InvocationInfo.PositionMessage)
$($ErrorRecord.ScriptStackTrace)
"@
        [System.IO.File]::WriteAllText(
            $logPath,
            $log,
            [System.Text.UTF8Encoding]::new($true)
        )
        return $logPath
    }
    catch {
        return $null
    }
}

trap {
    $failureRecord = $_
    $logPath = Write-FailureLog -ErrorRecord $failureRecord
    $message = if ($script:SetupPhase -eq '配置已写入') {
        '修改完成，无法自动打开 Codex，请手动打开。'
    }
    else {
        '运行失败，未完成配置，也不会重启 Codex。'
    }
    $message += "`r`n`r`n原因：$($failureRecord.Exception.Message)"
    if ($logPath) {
        $message += "`r`n`r`n错误日志：$logPath"
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show(
            $message,
            'Codex WebSocket 代理配置',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    catch {
        [Console]::Error.WriteLine($message)
    }
    exit 1
}

function Assert-RunningAsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    $isAdministrator = $principal.IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if ($isAdministrator) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $message = @"
此脚本必须以管理员身份运行。

请关闭当前窗口，然后右键单文件脚本，选择“以管理员身份运行”。

脚本不会自动申请权限，也不会在未授权的情况下继续操作。
"@

    if ('System.Windows.Forms.MessageBox' -as [type]) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $message,
            '需要管理员权限',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
    else {
        Write-Warning $message
    }

    exit 740
}

function Assert-SameInteractiveUser {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    try {
        $currentSessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
        $interactiveExplorer = Get-Process -Name 'explorer' -IncludeUserName -ErrorAction Stop |
            Where-Object { $_.SessionId -eq $currentSessionId -and $_.UserName } |
            Select-Object -First 1

        if ($interactiveExplorer -and -not [string]::Equals(
                $currentIdentity,
                [string]$interactiveExplorer.UserName,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw @"
检测到管理员账户与当前桌面登录账户不一致。

当前管理员账户：$currentIdentity
桌面登录账户：$($interactiveExplorer.UserName)

为避免把 .env 写入错误账户，脚本已停止。请使用当前登录账户自身的管理员权限运行；不要在 UAC 中输入另一个管理员账户。
"@
        }
    }
    catch {
        if ($_.Exception.Message -like '检测到管理员账户与当前桌面登录账户不一致*') {
            throw
        }

        Write-Verbose "无法核对桌面交互账户：$($_.Exception.Message)"
    }
}

function ConvertTo-HttpProxyCandidate {
    param(
        [string]$Value,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $rawValue = $Value.Trim().Trim('"').Trim("'")

    # Windows ProxyServer may use: http=host:port;https=host:port;socks=host:port
    if ($rawValue.Contains(';') -or $rawValue -match '^\w+=') {
        $entries = @{}

        foreach ($entry in $rawValue.Split(';')) {
            if ($entry -match '^\s*([^=]+)=(.+?)\s*$') {
                $entries[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim()
            }
        }

        if ($entries.ContainsKey('https')) {
            $rawValue = $entries['https']
        }
        elseif ($entries.ContainsKey('http')) {
            $rawValue = $entries['http']
        }
        else {
            return $null
        }
    }

    if ($rawValue -notmatch '^[a-z][a-z0-9+.-]*://') {
        $rawValue = "http://$rawValue"
    }

    $uri = $null
    if (-not [uri]::TryCreate($rawValue, [UriKind]::Absolute, [ref]$uri)) {
        return $null
    }

    if ($uri.Scheme -notin @('http', 'https') -or $uri.Port -lt 1) {
        return $null
    }

    [pscustomobject]@{
        Host   = $uri.Host
        Port   = $uri.Port
        Source = $Source
    }
}

function Get-ConfiguredProxyCandidate {
    foreach ($variableName in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($variableName, 'Process')
        $candidate = ConvertTo-HttpProxyCandidate -Value $value -Source "环境变量 $variableName"

        if ($candidate) {
            return $candidate
        }
    }

    try {
        $targetUri = [uri]'https://api.openai.com/'
        $systemProxyUri = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($targetUri)

        if ($systemProxyUri -and $systemProxyUri.AbsoluteUri -ne $targetUri.AbsoluteUri) {
            $candidate = ConvertTo-HttpProxyCandidate -Value $systemProxyUri.AbsoluteUri -Source 'Windows 系统代理'

            if ($candidate) {
                return $candidate
            }
        }
    }
    catch {
        Write-Verbose "无法通过 .NET 读取系统代理：$($_.Exception.Message)"
    }

    try {
        $internetSettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

        if ($internetSettings.ProxyEnable -eq 1) {
            $candidate = ConvertTo-HttpProxyCandidate -Value $internetSettings.ProxyServer -Source 'Windows 代理注册表'

            if ($candidate) {
                return $candidate
            }
        }
    }
    catch {
        Write-Verbose "无法读取 Windows 代理注册表：$($_.Exception.Message)"
    }

    return $null
}

function Test-LocalHttpProxyPort {
    param(
        [string]$HostName,
        [int]$Port
    )

    $client = [System.Net.Sockets.TcpClient]::new()

    try {
        $connectTask = $client.ConnectAsync($HostName, $Port)
        if (-not $connectTask.Wait(400) -or -not $client.Connected) {
            return $false
        }

        $stream = $client.GetStream()
        $stream.ReadTimeout = 900
        $request = "CONNECT api.openai.com:443 HTTP/1.1`r`nHost: api.openai.com:443`r`nConnection: close`r`n`r`n"
        $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($requestBytes, 0, $requestBytes.Length)

        $buffer = New-Object byte[] 128
        $readCount = $stream.Read($buffer, 0, $buffer.Length)
        if ($readCount -le 0) {
            return $false
        }

        $response = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $readCount)
        return $response -match '^HTTP/\d(?:\.\d)?\s+(?:200|407)\b'
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Request-ValidatedProxyPort {
    param([string]$HostName = '127.0.0.1')

    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

    while ($true) {
        $inputValue = [Microsoft.VisualBasic.Interaction]::InputBox(
            "未自动检测到可用代理。`r`n`r`n请输入代理软件的 HTTP/mixed 端口；点击取消或留空将安全退出。",
            '输入本机代理端口',
            ''
        ).Trim()

        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            throw '用户未提供代理端口，操作已取消。'
        }

        $parsedPort = 0
        if (-not [int]::TryParse($inputValue, [ref]$parsedPort) -or
            $parsedPort -lt 1 -or
            $parsedPort -gt 65535) {
            [void][System.Windows.Forms.MessageBox]::Show(
                '端口必须是 1 到 65535 之间的整数。',
                '代理端口无效',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            continue
        }

        if (-not (Test-LocalHttpProxyPort -HostName $HostName -Port $parsedPort)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "127.0.0.1:$parsedPort 无法完成 HTTP CONNECT。`r`n请确认代理软件正在运行，并填写 HTTP/mixed 端口。",
                '代理端口不可用',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            continue
        }

        return $parsedPort
    }
}

function Get-LocalProxyProcessCandidate {
    $proxyProcessPattern = '(?i)(clash|mihomo|v2ray|xray|sing-box|hiddify|nekoray|flclash)'
    $candidatePorts = [System.Collections.Generic.List[int]]::new()

    try {
        foreach ($connection in Get-NetTCPConnection -State Listen -ErrorAction Stop) {
            if ($connection.LocalAddress -notin @('127.0.0.1', '0.0.0.0', '::', '::1')) {
                continue
            }

            $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -match $proxyProcessPattern) {
                $candidatePorts.Add([int]$connection.LocalPort)
            }
        }
    }
    catch {
        Write-Verbose "无法枚举本地监听端口：$($_.Exception.Message)"
    }

    # Prefer common HTTP/mixed ports, then check any other port owned by a known proxy process.
    $preferredPorts = @(7890, 7897, 10809, 10808, 20171)
    $portsToTest = @($preferredPorts + $candidatePorts | Select-Object -Unique)

    foreach ($port in $portsToTest) {
        if (Test-LocalHttpProxyPort -HostName '127.0.0.1' -Port $port) {
            return [pscustomobject]@{
                Host   = '127.0.0.1'
                Port   = $port
                Source = '本地代理监听端口探测'
            }
        }
    }

    return $null
}

function Get-DescendantProcessIds {
    param(
        [int]$RootProcessId,
        [object[]]$ProcessTable
    )

    $descendants = [System.Collections.Generic.List[int]]::new()
    $pending = [System.Collections.Generic.Queue[int]]::new()
    $pending.Enqueue($RootProcessId)

    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()

        foreach ($child in $ProcessTable | Where-Object { $_.ParentProcessId -eq $parentId }) {
            $childId = [int]$child.ProcessId

            if (-not $descendants.Contains($childId)) {
                $descendants.Add($childId)
                $pending.Enqueue($childId)
            }
        }
    }

    return $descendants.ToArray()
}

function Get-CodexPackageInfo {
    param([object[]]$ProcessTable)

    $packageFullName = $null
    $packageFamilyName = $null
    $installLocation = $null
    $applicationId = $null
    $aumid = $null

    # Prefer the package that owns the currently running Codex process. This also
    # works when Appx cmdlets are unavailable or the Start menu index is stale.
    foreach ($process in $ProcessTable) {
        $candidateText = "$($process.ExecutablePath) $($process.CommandLine)"
        $packageMatch = [regex]::Match(
            $candidateText,
            '(?i)(?<root>[A-Z]:\\(?:Program Files\\)?WindowsApps\\(?<full>OpenAI\.Codex_[^\\\s\"]+))\\'
        )

        if ($packageMatch.Success) {
            $packageFullName = $packageMatch.Groups['full'].Value
            $installLocation = $packageMatch.Groups['root'].Value
            break
        }
    }

    $package = $null
    try {
        $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
        if ($packages.Count -gt 0) {
            if ($packageFullName) {
                $package = $packages | Where-Object {
                    $_.PackageFullName -eq $packageFullName
                } | Select-Object -First 1
            }

            if (-not $package) {
                $package = $packages | Sort-Object Version -Descending | Select-Object -First 1
            }

            $packageFullName = [string]$package.PackageFullName
            $packageFamilyName = [string]$package.PackageFamilyName
            $installLocation = [string]$package.InstallLocation

            try {
                $manifest = $package | Get-AppxPackageManifest -ErrorAction Stop
                $applicationId = @(
                    $manifest.Package.Applications.Application |
                        ForEach-Object { [string]$_.Id } |
                        Where-Object { $_ }
                ) | Select-Object -First 1
            }
            catch {
                Write-Verbose "无法通过 Appx cmdlet 读取 Codex 清单：$($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Verbose "无法通过 Appx cmdlet 查找 Codex：$($_.Exception.Message)"
    }

    if (-not $packageFamilyName -and $packageFullName -match '^OpenAI\.Codex_' -and
        $packageFullName.LastIndexOf('_') -gt 0) {
        $publisherId = $packageFullName.Substring($packageFullName.LastIndexOf('_') + 1)
        if ($publisherId) {
            $packageFamilyName = "OpenAI.Codex_$publisherId"
        }
    }

    # Get-StartApps already returns the complete AUMID and is independent of the
    # versioned WindowsApps executable path.
    try {
        $startApps = @(Get-StartApps -ErrorAction Stop |
            Where-Object { $_.AppID -match '(?i)^OpenAI\.Codex_[^!]+!.+$' })
        $startApp = $null

        if ($packageFamilyName -and $applicationId) {
            $expectedAumid = "$packageFamilyName!$applicationId"
            $startApp = $startApps | Where-Object {
                [string]::Equals(
                    [string]$_.AppID,
                    $expectedAumid,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            } | Select-Object -First 1
        }

        if (-not $startApp -and $packageFamilyName) {
            $familyPrefix = "$packageFamilyName!"
            $startApp = $startApps | Where-Object {
                ([string]$_.AppID).StartsWith(
                    $familyPrefix,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            } | Select-Object -First 1
        }

        if (-not $startApp -and -not $packageFamilyName) {
            $startApp = $startApps | Select-Object -First 1
        }

        if ($startApp) {
            $aumid = [string]$startApp.AppID
        }
    }
    catch {
        Write-Verbose "无法从开始菜单索引读取 Codex AUMID：$($_.Exception.Message)"
    }

    if (-not $applicationId -and $installLocation) {
        $manifestPath = Join-Path -Path $installLocation -ChildPath 'AppxManifest.xml'
        try {
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                [xml]$manifestXml = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
                $applicationId = @(
                    $manifestXml.Package.Applications.Application |
                        ForEach-Object { [string]$_.Id } |
                        Where-Object { $_ }
                ) | Select-Object -First 1
            }
        }
        catch {
            Write-Verbose "无法直接读取 Codex 应用清单：$($_.Exception.Message)"
        }
    }

    if (-not $aumid -and $packageFamilyName) {
        if (-not $applicationId) {
            # Current Codex Desktop packages use Application Id="App". The
            # manifest and Start menu paths above remain the preferred sources.
            $applicationId = 'App'
        }
        $aumid = "$packageFamilyName!$applicationId"
    }

    if (-not $aumid) {
        return $null
    }

    return [pscustomobject]@{
        Aumid             = $aumid
        PackageFullName   = $packageFullName
        PackageFamilyName = $packageFamilyName
        InstallLocation   = $installLocation
    }
}

function Get-CodexProcessSnapshot {
    param([object[]]$ProcessTable)

    if (-not $PSBoundParameters.ContainsKey('ProcessTable')) {
        $ProcessTable = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
    }

    $directIds = [System.Collections.Generic.List[int]]::new()
    $opaqueChatGptIds = [System.Collections.Generic.List[int]]::new()

    foreach ($process in $ProcessTable) {
        $executablePath = [string]$process.ExecutablePath
        $commandLine = [string]$process.CommandLine
        $processName = [string]$process.Name
        $isPackageExecutable = $executablePath -match
            '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\'
        $isNarrowCommandLineFallback = -not $executablePath -and
            $processName -match '(?i)^(?:ChatGPT|codex|codex-code-mode-host)\.exe$' -and
            $commandLine -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\'

        if ($isPackageExecutable -or $isNarrowCommandLineFallback) {
            $processId = [int]$process.ProcessId
            if (-not $directIds.Contains($processId)) {
                $directIds.Add($processId)
            }
        }
    }

    # CIM can hide ExecutablePath on some Windows builds. Administrators can
    # usually still read Process.Path, so use it as a narrow package-only fallback.
    foreach ($process in Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue) {
        $processPath = $null
        try {
            $processPath = [string]$process.Path
            if ($processPath -match
                '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$' -and
                -not $directIds.Contains([int]$process.Id)) {
                $directIds.Add([int]$process.Id)
            }
        }
        catch {
            Write-Verbose "无法读取 ChatGPT 进程 $($process.Id) 的路径。"
        }

        if (-not $processPath -and -not $opaqueChatGptIds.Contains([int]$process.Id)) {
            $opaqueChatGptIds.Add([int]$process.Id)
        }
    }

    $allIds = [System.Collections.Generic.List[int]]::new()
    foreach ($directId in $directIds) {
        if (-not $allIds.Contains($directId)) {
            $allIds.Add($directId)
        }

        foreach ($descendantId in Get-DescendantProcessIds `
            -RootProcessId $directId -ProcessTable $ProcessTable) {
            if (-not $allIds.Contains($descendantId)) {
                $allIds.Add($descendantId)
            }
        }
    }

    return [pscustomobject]@{
        ProcessTable = $ProcessTable
        DirectIds    = $directIds.ToArray()
        AllIds       = $allIds.ToArray()
        OpaqueChatGptIds = $opaqueChatGptIds.ToArray()
    }
}

function Get-ProcessAncestryIds {
    param(
        [int]$StartProcessId,
        [object[]]$ProcessTable
    )

    $result = [System.Collections.Generic.List[int]]::new()
    $currentId = $StartProcessId

    while ($currentId -gt 0 -and -not $result.Contains($currentId)) {
        $result.Add($currentId)
        $entry = $ProcessTable | Where-Object {
            [int]$_.ProcessId -eq $currentId
        } | Select-Object -First 1

        if (-not $entry) {
            break
        }

        $currentId = [int]$entry.ParentProcessId
    }

    return $result.ToArray()
}

function Invoke-CodexPackageTermination {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageFullName
    )

    if (-not ('CodexSetup.PackageProcessControl' -as [type])) {
        $typeDefinition = @'
using System;
using System.Runtime.InteropServices;

namespace CodexSetup
{
    [ComImport]
    [Guid("B1AEC16F-2383-4852-B0E9-8F0B1DC66B4D")]
    [ClassInterface(ClassInterfaceType.None)]
    internal class PackageDebugSettingsClass
    {
    }

    [ComImport]
    [Guid("F27C3930-8029-4AD1-94E3-3DBA417810C1")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPackageDebugSettings
    {
        [PreserveSig]
        int EnableDebugging(
            [MarshalAs(UnmanagedType.LPWStr)] string packageFullName,
            [MarshalAs(UnmanagedType.LPWStr)] string debuggerCommandLine,
            IntPtr environment);

        [PreserveSig]
        int DisableDebugging([MarshalAs(UnmanagedType.LPWStr)] string packageFullName);

        [PreserveSig]
        int Suspend([MarshalAs(UnmanagedType.LPWStr)] string packageFullName);

        [PreserveSig]
        int Resume([MarshalAs(UnmanagedType.LPWStr)] string packageFullName);

        [PreserveSig]
        int TerminateAllProcesses([MarshalAs(UnmanagedType.LPWStr)] string packageFullName);
    }

    public static class PackageProcessControl
    {
        public static void TerminateAll(string packageFullName)
        {
            object instance = null;
            try
            {
                instance = new PackageDebugSettingsClass();
                IPackageDebugSettings settings = (IPackageDebugSettings)instance;
                int result = settings.TerminateAllProcesses(packageFullName);
                if (result < 0)
                {
                    Marshal.ThrowExceptionForHR(result);
                }
            }
            finally
            {
                if (instance != null && Marshal.IsComObject(instance))
                {
                    Marshal.FinalReleaseComObject(instance);
                }
            }
        }
    }
}
'@
        [void](Add-Type -TypeDefinition $typeDefinition -Language CSharp -ErrorAction Stop)
    }

    [CodexSetup.PackageProcessControl]::TerminateAll($PackageFullName)
}

function Stop-CodexPackageProcesses {
    param([string]$PackageFullName)

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $quietSince = $null
    $packageTerminationSucceeded = $false

    while ([DateTime]::UtcNow -lt $deadline) {
        $processTable = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
        $snapshot = Get-CodexProcessSnapshot -ProcessTable $processTable
        $targetIds = @($snapshot.AllIds)

        $protectedIds = @(Get-ProcessAncestryIds -StartProcessId $PID -ProcessTable $processTable)
        $unsafeIds = @($snapshot.AllIds | Where-Object { $protectedIds -contains $_ })
        if ($unsafeIds.Count -gt 0) {
            throw '检测到本脚本是从 Codex 内部启动的，无法在不终止脚本自身的情况下重启。请从资源管理器中右键以管理员身份运行本脚本。'
        }

        if ($PackageFullName) {
            try {
                Invoke-CodexPackageTermination -PackageFullName $PackageFullName
                $packageTerminationSucceeded = $true
                Start-Sleep -Milliseconds 100
                $processTable = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
                $snapshot = Get-CodexProcessSnapshot -ProcessTable $processTable
                $targetIds = @($targetIds + $snapshot.AllIds | Select-Object -Unique)
            }
            catch {
                Write-Verbose "包级终止接口不可用：$($_.Exception.Message)"
            }
        }

        if ($snapshot.OpaqueChatGptIds.Count -gt 0 -and
            -not $packageTerminationSucceeded -and
            $snapshot.AllIds.Count -eq 0) {
            throw '检测到无法识别归属的 ChatGPT 进程，无法确认旧 Codex 已关闭。为避免启动第二个实例，请手动关闭 Codex 后再打开。'
        }

        # The package API closes package-owned executables, but an external CLI
        # child can become orphaned at that moment. Stop every PID captured before
        # package termination as well as any PID found afterward.
        foreach ($processId in $targetIds) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }

        $capturedProcessesStillRunning = @($targetIds | Where-Object {
                Get-Process -Id $_ -ErrorAction SilentlyContinue
            })
        if ($capturedProcessesStillRunning.Count -gt 0) {
            $quietSince = $null
            Start-Sleep -Milliseconds 250
            continue
        }

        if ($snapshot.AllIds.Count -eq 0) {
            if (-not $quietSince) {
                $quietSince = [DateTime]::UtcNow
            }

            if (([DateTime]::UtcNow - $quietSince).TotalMilliseconds -ge 1500) {
                return $packageTerminationSucceeded
            }

            Start-Sleep -Milliseconds 250
            continue
        }

        $quietSince = $null

        Start-Sleep -Milliseconds 250
    }

    $remaining = Get-CodexProcessSnapshot
    if ($remaining.AllIds.Count -gt 0) {
        throw "仍有 $($remaining.AllIds.Count) 个 Codex 相关进程未能关闭。"
    }

    if ($remaining.OpaqueChatGptIds.Count -gt 0 -and -not $packageTerminationSucceeded) {
        throw '仍有无法识别归属的 ChatGPT 进程，无法确认旧 Codex 已关闭。'
    }

    throw '未能在 10 秒内持续确认 Codex 已完全关闭。'
}

function Restart-CodexDesktop {
    $initialProcessTable = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
    $packageInfo = Get-CodexPackageInfo -ProcessTable $initialProcessTable

    if (-not $packageInfo) {
        return $false
    }

    $initialSnapshot = Get-CodexProcessSnapshot -ProcessTable $initialProcessTable
    $initialIds = @($initialSnapshot.AllIds)
    $packageTerminationSucceeded = $false
    if ($packageInfo.PackageFullName -or
        $initialSnapshot.AllIds.Count -gt 0 -or
        $initialSnapshot.OpaqueChatGptIds.Count -gt 0) {
        $packageTerminationSucceeded = Stop-CodexPackageProcesses `
            -PackageFullName $packageInfo.PackageFullName
    }

    $closedSnapshot = Get-CodexProcessSnapshot
    if ($closedSnapshot.AllIds.Count -gt 0) {
        throw 'Codex 相关进程没有完全退出，已取消自动启动。'
    }
    if ($closedSnapshot.OpaqueChatGptIds.Count -gt 0 -and
        -not $packageTerminationSucceeded) {
        throw '无法确认旧 Codex 是否已经退出，已取消自动启动以避免重复实例。'
    }

    # The setup script is elevated, but Codex must run as the normal interactive
    # user. Explorer resolves the version-independent AUMID through AppsFolder.
    $shell = New-Object -ComObject 'Shell.Application'
    $shell.ShellExecute("shell:AppsFolder\$($packageInfo.Aumid)", '', '', 'open', 1)

    $launchDeadline = [DateTime]::UtcNow.AddSeconds(25)
    $stableSince = $null
    while ([DateTime]::UtcNow -lt $launchDeadline) {
        Start-Sleep -Milliseconds 250
        $startedSnapshot = Get-CodexProcessSnapshot
        $newDirectIds = @($startedSnapshot.DirectIds | Where-Object {
                $initialIds -notcontains $_
            })

        if ($newDirectIds.Count -gt 0) {
            if (-not $stableSince) {
                $stableSince = [DateTime]::UtcNow
            }

            if (([DateTime]::UtcNow - $stableSince).TotalMilliseconds -ge 1500) {
                return $true
            }
        }
        else {
            $stableSince = $null
        }
    }

    return $false
}

function Confirm-AndRestartCodexDesktop {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

    $message = @"
代理配置已经写入 .codex\.env。

需要重启 Codex Desktop 才能生效。
立即重启会关闭当前 Codex 窗口，请先确认正在执行的任务可以安全恢复。

是否现在自动重启 Codex Desktop？
"@

    $choice = [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Codex WebSocket 代理配置',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )

    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Host '用户取消了自动重启。请稍后手动重启 Codex Desktop。' -ForegroundColor Yellow
        return
    }

    Write-Host '正在重启 Codex Desktop...' -ForegroundColor Cyan
    if (-not (Restart-CodexDesktop)) {
        throw '自动启动验证失败。'
    }

    Write-Host 'Codex Desktop 已重新启动。' -ForegroundColor Green
}

Assert-RunningAsAdministrator
Assert-SameInteractiveUser

if ($ProxyPort -eq 0) {
    $detectedProxy = Get-ConfiguredProxyCandidate

    if ($detectedProxy -and
        -not (Test-LocalHttpProxyPort -HostName $detectedProxy.Host -Port $detectedProxy.Port)) {
        Write-Warning "检测到的代理 $($detectedProxy.Host):$($detectedProxy.Port) 无法完成 HTTP CONNECT，已忽略。"
        $detectedProxy = $null
    }

    if (-not $detectedProxy) {
        $detectedProxy = Get-LocalProxyProcessCandidate
    }

    if ($detectedProxy) {
        $ProxyHost = $detectedProxy.Host
        $ProxyPort = $detectedProxy.Port
        Write-Host "自动检测到代理：http://${ProxyHost}:${ProxyPort}（来源：$($detectedProxy.Source)）" -ForegroundColor Cyan
    }
}

if ($ProxyPort -eq 0) {
    $ProxyPort = Request-ValidatedProxyPort -HostName '127.0.0.1'
}

if ([string]::IsNullOrWhiteSpace($ProxyHost)) {
    $ProxyHost = '127.0.0.1'
}

if (-not (Test-LocalHttpProxyPort -HostName $ProxyHost -Port $ProxyPort)) {
    throw "代理安全检查失败：${ProxyHost}:${ProxyPort} 无法完成 HTTP CONNECT。未写入 .env，也不会重启 Codex。"
}

$proxyUrl = "http://${ProxyHost}:${ProxyPort}"
$currentUserProfile = [System.Environment]::GetFolderPath(
    [System.Environment+SpecialFolder]::UserProfile
)

if ([string]::IsNullOrWhiteSpace($currentUserProfile)) {
    throw '安全检查失败：无法确定当前 Windows 用户目录。'
}

$CodexDir = [System.IO.Path]::GetFullPath((Join-Path $currentUserProfile '.codex'))
$envPath = [System.IO.Path]::GetFullPath((Join-Path $CodexDir '.env'))

if (-not [string]::Equals(
        [System.IO.Path]::GetDirectoryName($envPath),
        $CodexDir,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or [System.IO.Path]::GetFileName($envPath) -ne '.env') {
    throw '安全检查失败：目标必须严格等于当前用户的 .codex\.env。'
}

if ((Test-Path -LiteralPath $CodexDir) -and
    -not (Test-Path -LiteralPath $CodexDir -PathType Container)) {
    throw '安全检查失败：.codex 路径已存在，但不是目录。'
}

if (-not (Test-Path -LiteralPath $CodexDir -PathType Container)) {
    New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null
}

$codexDirectoryItem = Get-Item -LiteralPath $CodexDir -Force -ErrorAction Stop
if (($codexDirectoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw '安全检查失败：.codex 目录是符号链接或目录联接，脚本拒绝写入。'
}

$originalEnvExists = Test-Path -LiteralPath $envPath
$originalEnvBytes = $null

if ($originalEnvExists) {
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        throw '安全检查失败：.env 路径存在，但不是普通文件。'
    }

    $envItem = Get-Item -LiteralPath $envPath -Force -ErrorAction Stop
    if (($envItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw '安全检查失败：.env 是符号链接，脚本拒绝写入。'
    }

    if (($envItem.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
        throw '安全检查失败：现有 .env 是只读文件，脚本不会修改。'
    }

    if ($envItem.Length -gt 1MB) {
        throw '安全检查失败：现有 .env 大于 1 MB，脚本不会修改异常大小的配置文件。'
    }

    $originalEnvBytes = [System.IO.File]::ReadAllBytes($envPath)
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        [void]$strictUtf8.GetString($originalEnvBytes)
    }
    catch {
        throw '安全检查失败：现有 .env 不是有效的 UTF-8 文件，未做任何修改。'
    }
}

$desiredValues = [ordered]@{
    HTTP_PROXY  = $proxyUrl
    HTTPS_PROXY = $proxyUrl
    NO_PROXY    = "localhost,127.0.0.1,::1"
}

$lines = [System.Collections.Generic.List[string]]::new()

if ($originalEnvExists) {
    foreach ($line in [System.IO.File]::ReadAllLines($envPath)) {
        $lines.Add($line)
    }
}

$updatedKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$outputLines = [System.Collections.Generic.List[string]]::new()

foreach ($line in $lines) {
    if ($line -match '^\s*(?:export\s+)?(HTTP_PROXY|HTTPS_PROXY|NO_PROXY)\s*=') {
        $key = $Matches[1].ToUpperInvariant()

        if (-not $updatedKeys.Contains($key)) {
            $outputLines.Add(('{0}="{1}"' -f $key, $desiredValues[$key]))
            [void]$updatedKeys.Add($key)
        }

        continue
    }

    $outputLines.Add($line)
}

foreach ($entry in $desiredValues.GetEnumerator()) {
    if (-not $updatedKeys.Contains($entry.Key)) {
        $outputLines.Add(('{0}="{1}"' -f $entry.Key, $entry.Value))
    }
}

$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
$content = [string]::Join([Environment]::NewLine, $outputLines) + [Environment]::NewLine

try {
    [System.IO.File]::WriteAllText($envPath, $content, $utf8WithoutBom)
    $verifiedContent = [System.IO.File]::ReadAllText($envPath, $utf8WithoutBom)

    if ($verifiedContent -ne $content) {
        throw '写入后的 .env 内容校验不一致。'
    }
}
catch {
    $writeFailure = $_.Exception.Message

    try {
        if ($originalEnvExists) {
            [System.IO.File]::WriteAllBytes($envPath, $originalEnvBytes)
        }
        elseif (Test-Path -LiteralPath $envPath -PathType Leaf) {
            [System.IO.File]::Delete($envPath)
        }
    }
    catch {
        throw "写入 .env 失败，并且原地回滚也失败：$writeFailure；回滚错误：$($_.Exception.Message)"
    }

    throw "写入 .env 失败，已恢复写入前状态：$writeFailure"
}

$script:SetupPhase = '配置已写入'

Write-Host ""
Write-Host "Codex WebSocket 代理配置已写入：" -ForegroundColor Green
Write-Host $envPath
Write-Host ""
Write-Host "HTTP_PROXY=$proxyUrl"
Write-Host "HTTPS_PROXY=$proxyUrl"
Write-Host "NO_PROXY=localhost,127.0.0.1,::1"

Write-Host ""
Confirm-AndRestartCodexDesktop
