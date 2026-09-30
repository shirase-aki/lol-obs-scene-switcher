<#
LoL OBS Scene Switcher v0.1.1
League of Legends の試合開始/終了を検知して、OBSのシーンを自動で切り替える。

- 監視するもの : "League of Legends.exe" プロセスが存在するか(Get-Process)のみ。
                 画面・メモリ・ゲーム内データ・チャット等は一切読まない。
- 接続するもの : 設定したOBS WebSocketサーバー(既定 127.0.0.1:4455)のみ。
                 それ以外のネットワーク通信はしない(テレメトリ・更新確認なし)。
- 保存するもの : %APPDATA%\LolObsSceneSwitcher\settings.json
                 (パスワードはWindows DPAPIで暗号化。詳細は README.md)
- 管理者権限   : 不要。
#>

[CmdletBinding()]
param([switch]$NoGui)   # -NoGui: 関数だけ読み込む(テスト用)

$ErrorActionPreference = 'Stop'

$script:AppName     = 'LoL OBS Scene Switcher'
$script:AppVersion  = '0.1.1'
$script:ProcessName = 'League of Legends'   # ロビー(LeagueClient)ではなく試合本体
$script:SettingsDir  = Join-Path $env:APPDATA 'LolObsSceneSwitcher'
$script:SettingsPath = Join-Path $script:SettingsDir 'settings.json'

# --- 設定の保存と復元 ------------------------------------------------------

function Get-DefaultSettings {
    [ordered]@{
        Host              = '127.0.0.1'
        Port              = 4455
        PasswordProtected = ''     # DPAPI暗号化済み文字列(平文は保存しない)
        GameScene         = ''
        IdleScene         = ''
        Enabled           = $true
    }
}

function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    ConvertTo-SecureString -String $Text -AsPlainText -Force | ConvertFrom-SecureString
}

function Unprotect-Text([string]$Encrypted) {
    if (-not $Encrypted) { return '' }
    try {
        $ss = ConvertTo-SecureString -String $Encrypted
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        return ''   # 別ユーザー/別PCでは復号できない -> 再入力してもらう
    }
}

function Import-Settings {
    $s = Get-DefaultSettings
    if (Test-Path $script:SettingsPath) {
        try {
            $j = [IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) {
                if ($null -ne $j.$k) { $s[$k] = $j.$k }
            }
        } catch { }   # 壊れていたら既定値で起動
    }
    $s
}

function Export-Settings($Settings) {
    if (-not (Test-Path $script:SettingsDir)) {
        New-Item -ItemType Directory -Path $script:SettingsDir | Out-Null
    }
    $json = $Settings | ConvertTo-Json
    [IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object Text.UTF8Encoding($false)))
}

# --- obs-websocket v5 クライアント ------------------------------------------
# 自分用スクリプト(watch-lol-process.ps1)で実機検証済みの実装をベースにしている。

function Receive-ObsMessage($Ws, [int]$TimeoutMs = 3000) {
    $buffer = New-Object byte[] 8192
    $segment = New-Object System.ArraySegment[byte] (,$buffer)
    $ms = New-Object System.IO.MemoryStream
    do {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter($TimeoutMs)
        try {
            $result = $Ws.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
        } catch {
            throw "TIMEOUT: OBSから応答がありません ($($_.Exception.Message))"
        }
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            throw "CLOSED: OBSが接続を閉じました (code $([int]$Ws.CloseStatus))"
        }
        $ms.Write($buffer, 0, $result.Count)
    } while (-not $result.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}

function Send-ObsMessage($Ws, $Object) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
    $segment = New-Object System.ArraySegment[byte] (,$bytes)
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(3000)
    $Ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null
}

function Get-ObsAuthString([string]$Password, [string]$Salt, [string]$Challenge) {
    # base64(sha256(base64(sha256(password + salt)) + challenge))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $secret = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Password + $Salt)))
        [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret + $Challenge)))
    } finally { $sha.Dispose() }
}

function Connect-Obs([string]$HostName, [int]$Port, [string]$Password) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    try {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(3000)
        try {
            $ws.ConnectAsync([Uri]("ws://{0}:{1}" -f $HostName, $Port), $cts.Token).GetAwaiter().GetResult() | Out-Null
        } catch {
            throw "CONNECT: $($_.Exception.Message)"
        }
        $hello = Receive-ObsMessage $ws
        if ($hello.op -ne 0) { throw "PROTOCOL: Hello (op=0) が来ませんでした" }
        # eventSubscriptions=0: OBSのイベントは不要。受信キューに溜まるのを防ぐ。
        $identify = [ordered]@{ op = 1; d = [ordered]@{ rpcVersion = $hello.d.rpcVersion; eventSubscriptions = 0 } }
        if ($hello.d.authentication) {
            if (-not $Password) { throw "AUTH: OBSはパスワードが必要です" }
            $identify.d.authentication = Get-ObsAuthString $Password $hello.d.authentication.salt $hello.d.authentication.challenge
        }
        Send-ObsMessage $ws $identify
        $identified = Receive-ObsMessage $ws
        if ($identified.op -ne 2) { throw "PROTOCOL: Identified (op=2) が来ませんでした" }
        return $ws
    } catch {
        $ws.Dispose()
        throw
    }
}

function Invoke-ObsRequest($Ws, [string]$Type, $Data = $null) {
    $id = [guid]::NewGuid().ToString()
    $d = [ordered]@{ requestType = $Type; requestId = $id }
    if ($Data) { $d.requestData = $Data }
    Send-ObsMessage $Ws ([ordered]@{ op = 6; d = $d })
    for ($i = 0; $i -lt 20; $i++) {
        $m = Receive-ObsMessage $Ws
        if ($m.op -eq 7 -and $m.d.requestId -eq $id) {
            if (-not $m.d.requestStatus.result) {
                # 接続は生きている(例: 存在しないシーン名)。切断扱いにしない印として OBSERR: を付ける
                throw "OBSERR: $Type に失敗: $($m.d.requestStatus.comment)"
            }
            return $m
        }
    }
    throw "TIMEOUT: $Type の応答がありません"
}

function Get-ObsSceneNames($Ws) {
    $m = Invoke-ObsRequest $Ws 'GetSceneList'
    @($m.d.responseData.scenes | ForEach-Object { $_.sceneName })
}

function Set-ObsScene($Ws, [string]$SceneName) {
    Invoke-ObsRequest $Ws 'SetCurrentProgramScene' ([ordered]@{ sceneName = $SceneName }) | Out-Null
}

function Close-Obs($Ws) {
    if (-not $Ws) { return }
    try {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(1000)
        $Ws.CloseOutputAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cts.Token).GetAwaiter().GetResult() | Out-Null
    } catch { }
    $Ws.Dispose()
}

function Get-FriendlyError($ErrorRecord) {
    $m = $ErrorRecord.Exception.Message
    if ($m -match '4009|^AUTH:') { return 'パスワードが違います' }
    if ($m -match '^CONNECT:')   { return 'OBSに接続できません(OBSの起動と WebSocketサーバー有効化を確認)' }
    $m -replace '^(OBSERR|TIMEOUT|CLOSED|PROTOCOL): ', ''
}

# --- LoL検知(2回連続で同じ結果なら確定) -------------------------------------

function Test-LolRunning {
    [bool](Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
}

function Update-Debounce($State, [bool]$Reading) {
    # 状態変化が「新たに確定した」tickでだけ $true を返す
    if ($Reading -eq $State.LastReading) { $State.Count++ }
    else { $State.LastReading = $Reading; $State.Count = 1 }
    if ($State.Count -ge 2 -and $Reading -ne $State.Confirmed) {
        $State.Confirmed = $Reading
        return $true
    }
    $false
}

# --- GUI ---------------------------------------------------------------------

function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\LolObsSceneSwitcher', [ref]$created)
    if (-not $created) {
        [System.Windows.Forms.MessageBox]::Show('すでに起動しています。', $script:AppName) | Out-Null
        return
    }

    $script:Settings = Import-Settings
    $script:Password = Unprotect-Text $script:Settings.PasswordProtected
    $script:Deb   = @{ LastReading = $false; Count = 0; Confirmed = $false }
    $script:State = @{ Ws = $null; NextRetry = Get-Date; Error = ''; Pending = $false; Desired = ''; LastSwitch = ''; Notice = '' }

    $font = New-Object System.Drawing.Font('Yu Gothic UI', 9)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$script:AppName v$script:AppVersion"
    $form.ClientSize = New-Object System.Drawing.Size(444, 440)
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = $font
    $iconPath = Join-Path $PSScriptRoot 'icon.ico'
    if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { } }

    function Add-Ctl($parent, $ctl, $x, $y, $w, $h, $text = '') {
        $ctl.Location = New-Object System.Drawing.Point($x, $y)
        $ctl.Size = New-Object System.Drawing.Size($w, $h)
        if ($text) { $ctl.Text = $text }
        $parent.Controls.Add($ctl)
        $ctl
    }

    # 1. OBS接続
    $g1 = Add-Ctl $form (New-Object System.Windows.Forms.GroupBox) 12 10 420 164 '1. OBS接続 (WebSocket)'
    Add-Ctl $g1 (New-Object System.Windows.Forms.Label) 12 28 60 20 'ホスト' | Out-Null
    $tbHost = Add-Ctl $g1 (New-Object System.Windows.Forms.TextBox) 82 25 140 22
    Add-Ctl $g1 (New-Object System.Windows.Forms.Label) 236 28 50 20 'ポート' | Out-Null
    $tbPort = Add-Ctl $g1 (New-Object System.Windows.Forms.TextBox) 290 25 70 22
    Add-Ctl $g1 (New-Object System.Windows.Forms.Label) 12 58 300 20 'OBS WebSocket パスワード' | Out-Null
    $tbPass = Add-Ctl $g1 (New-Object System.Windows.Forms.TextBox) 12 80 286 22
    $tbPass.UseSystemPasswordChar = $true
    $btnHelp = Add-Ctl $g1 (New-Object System.Windows.Forms.Button) 306 78 100 26 '？ 確認方法'
    $lblHint = Add-Ctl $g1 (New-Object System.Windows.Forms.Label) 12 106 396 18 'OBS → ツール → WebSocketサーバー設定 で確認できます'
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $btnConnect = Add-Ctl $g1 (New-Object System.Windows.Forms.Button) 12 128 394 28 '接続 / シーン一覧を更新'

    # 2. シーン
    $g2 = Add-Ctl $form (New-Object System.Windows.Forms.GroupBox) 12 182 420 100 '2. シーン設定'
    Add-Ctl $g2 (New-Object System.Windows.Forms.Label) 12 30 80 20 '試合中のシーン' | Out-Null
    $cbGame = Add-Ctl $g2 (New-Object System.Windows.Forms.ComboBox) 110 27 290 24
    Add-Ctl $g2 (New-Object System.Windows.Forms.Label) 12 64 80 20 '試合外のシーン' | Out-Null
    $cbIdle = Add-Ctl $g2 (New-Object System.Windows.Forms.ComboBox) 110 61 290 24

    $chkEnabled = Add-Ctl $form (New-Object System.Windows.Forms.CheckBox) 16 290 300 22 '自動切替を有効にする'

    # 3. 状態
    $g3 = Add-Ctl $form (New-Object System.Windows.Forms.GroupBox) 12 318 420 084 '状態'
    $lblObs  = Add-Ctl $g3 (New-Object System.Windows.Forms.Label) 12 22 396 20
    $lblLol  = Add-Ctl $g3 (New-Object System.Windows.Forms.Label) 12 44 396 20
    $lblLast = Add-Ctl $g3 (New-Object System.Windows.Forms.Label) 12 62 396 18
    $lblObs.Font = New-Object System.Drawing.Font('Yu Gothic UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblLol.Font = $lblObs.Font
    $lblLast.ForeColor = [System.Drawing.Color]::DimGray

    $lblFoot = Add-Ctl $form (New-Object System.Windows.Forms.Label) 14 408 420 24 "通信先は設定したOBSのみ。外部サーバーへの送信・テレメトリなし。"
    $lblFoot.ForeColor = [System.Drawing.Color]::DimGray

    # 値の反映
    $tbHost.Text = [string]$script:Settings.Host
    $tbPort.Text = [string]$script:Settings.Port
    $tbPass.Text = $script:Password
    $cbGame.Text = [string]$script:Settings.GameScene
    $cbIdle.Text = [string]$script:Settings.IdleScene
    $chkEnabled.Checked = [bool]$script:Settings.Enabled

    function Save-FromFields {
        if ($script:UpdatingCombos) { return }
        $port = 0
        if (-not [int]::TryParse($tbPort.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { $port = 4455; $tbPort.Text = '4455' }
        $script:Settings.Host = $tbHost.Text.Trim()
        $script:Settings.Port = $port
        $script:Password = $tbPass.Text
        $script:Settings.PasswordProtected = Protect-Text $script:Password
        $script:Settings.GameScene = $cbGame.Text.Trim()
        $script:Settings.IdleScene = $cbIdle.Text.Trim()
        $script:Settings.Enabled = $chkEnabled.Checked
        try { Export-Settings $script:Settings } catch { $script:State.Notice = "設定を保存できません: $($_.Exception.Message)" }
    }

    function Disconnect-Obs {
        Close-Obs $script:State.Ws
        $script:State.Ws = $null
    }

    function Update-SceneCombos($names) {
        $script:UpdatingCombos = $true   # 一覧の入れ替え中に空の値を保存しない
        try {
            foreach ($cb in @($cbGame, $cbIdle)) {
                $cur = $cb.Text
                $cb.Items.Clear()
                $cb.Items.AddRange([object[]]$names)
                $cb.Text = $cur
            }
        } finally { $script:UpdatingCombos = $false }
    }

    function Connect-AndLoadScenes {
        try {
            $ws = Connect-Obs $script:Settings.Host ([int]$script:Settings.Port) $script:Password
            $script:State.Ws = $ws
            $script:State.Error = ''
            Update-SceneCombos (Get-ObsSceneNames $ws)
        } catch {
            Disconnect-Obs
            $script:State.Error = Get-FriendlyError $_
            $retrySec = if ($_.Exception.Message -match '4009|^AUTH:') { 15 } else { 5 }
            $script:State.NextRetry = (Get-Date).AddSeconds($retrySec)
        }
    }

    function Update-StatusView {
        $st = $script:State
        if ($st.Ws) {
            $lblObs.Text = 'OBS: 接続済み'; $lblObs.ForeColor = [System.Drawing.Color]::SeaGreen
        } else {
            $lblObs.Text = if ($st.Error) { "OBS: 未接続 - $($st.Error)" } else { 'OBS: 未接続' }
            $lblObs.ForeColor = [System.Drawing.Color]::Firebrick
        }
        if ($script:Deb.Confirmed) { $lblLol.Text = 'LoL: 試合中'; $lblLol.ForeColor = [System.Drawing.Color]::DarkOrange }
        else { $lblLol.Text = 'LoL: 待機中'; $lblLol.ForeColor = [System.Drawing.Color]::DimGray }
        $lblLast.Text = if ($st.Notice) { $st.Notice } elseif ($st.LastSwitch) { "最後の自動切替: $($st.LastSwitch)" } else { '' }
    }

    function Invoke-Tick {
        $st = $script:State
        $reading = Test-LolRunning
        if (Update-Debounce $script:Deb $reading) {
            if ($script:Settings.Enabled) {
                $st.Desired = if ($script:Deb.Confirmed) { $script:Settings.GameScene } else { $script:Settings.IdleScene }
                $st.Pending = $true
            }
        }
        if (-not $st.Ws -and (Get-Date) -ge $st.NextRetry -and $script:Settings.Host) {
            Connect-AndLoadScenes
        }
        if ($st.Ws -and $st.Pending) {
            if (-not $st.Desired) {
                $st.Pending = $false
                $st.Notice = '切替先のシーンが未設定です'
            } else {
                try {
                    Set-ObsScene $st.Ws $st.Desired
                    $st.Pending = $false
                    $st.Notice = ''
                    $st.LastSwitch = "{0:HH:mm:ss} → {1}" -f (Get-Date), $st.Desired
                } catch {
                    if ($_.Exception.Message -like 'OBSERR:*') {
                        $st.Pending = $false
                        $st.Notice = "切替失敗: $(Get-FriendlyError $_)"   # シーン名の誤りなど。接続は維持
                    } else {
                        Disconnect-Obs
                        $st.Error = Get-FriendlyError $_
                        $st.NextRetry = Get-Date   # 切断 -> 再接続後に保留中の切替をやり直す
                    }
                }
            }
        }
        Update-StatusView
    }

    $btnHelp.Add_Click({
        $msg = @(
            'OBS WebSocket パスワードの確認方法',
            '',
            '1. OBS のメニュー「ツール」→「WebSocketサーバー設定」を開く',
            '2. 「WebSocketサーバーを有効にする」にチェックを入れる',
            '3. 「認証を有効にする」にチェックを入れる',
            '4. 「サーバーパスワード」に表示されている文字列を、このツールの',
            '   「OBS WebSocket パスワード」欄に入力する',
            '   (「パスワードを生成」で新しく作ってもOKです)',
            '5. 「サーバーポート」の数字(ふつうは 4455)を、このツールの「ポート」に入力する',
            '6. 「接続 / シーン一覧を更新」を押す',
            '',
            '※ OBS 28 以降は WebSocket が標準で入っています。',
            '※ 認証を有効にしていない場合、パスワードは空欄で接続できます。'
        ) -join "`n"
        [System.Windows.Forms.MessageBox]::Show($msg, 'OBS WebSocket の設定場所') | Out-Null
    })
    $btnConnect.Add_Click({
        Save-FromFields
        Disconnect-Obs
        $script:State.Notice = ''
        Connect-AndLoadScenes
        Update-StatusView
    })
    foreach ($c in @($cbGame, $cbIdle)) {
        # TextChanged: 選択・入力の直後に確実に反映される
        # (SelectionChangeCommitted の時点では .Text がまだ古い値のため使わない)
        $c.Add_TextChanged({ Save-FromFields })
    }
    $chkEnabled.Add_CheckedChanged({
        Save-FromFields
        if (-not $chkEnabled.Checked) { $script:State.Pending = $false }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({ try { Invoke-Tick } catch { $script:State.Notice = "内部エラー: $($_.Exception.Message)" } })

    $form.Add_FormClosing({
        $timer.Stop()
        Save-FromFields
        Disconnect-Obs
    })

    Update-StatusView
    $timer.Start()
    try { [System.Windows.Forms.Application]::Run($form) }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

if (-not $NoGui) {
    try { Start-Gui }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("起動に失敗しました:`n$($_.Exception.Message)", $script:AppName) | Out-Null
    }
}
