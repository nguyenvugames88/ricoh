# ===================================================
#  CÔNG CỤ CÀI ĐẶT MÁY IN RICOH TỰ ĐỘNG - v2.1
#  - Tải driver từ Google Drive (hỗ trợ trang xác nhận tải file lớn)
#  - Hỗ trợ gói driver dạng EXE SFX hoặc ZIP (giải nén bằng .NET, không cần 7-Zip)
#  - Đăng ký driver bằng pnputil, tạo TCP/IP Port, Add-Printer, cấu hình User Code
#  - Tự động lấy tên driver từ file oemsetup.inf trong gói
#  - Đặt mặc định khổ giấy A4 và TẮT chế độ in 2 mặt (simplex)
#
#  Cách dùng:
#    powershell -ExecutionPolicy Bypass -File ricoh-print.ps1
# ===================================================

# ---------------- CẤU HÌNH ----------------
# File ID của gói driver trên Google Drive
# (Link dạng: https://drive.google.com/file/d/<FILE_ID>/view)
$DriverFileId = "1zTG7h5aNUyS-ANAzWGwU4nEfYNahBlMa"

# ===================================================
# 0. TỰ ĐỘNG NÂNG QUYỀN ADMINISTRATOR
# ===================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    if ($PSCommandPath) {
        Write-Host "[*] Đang yêu cầu quyền Quản trị (Admin)..." -ForegroundColor Yellow
        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    } else {
        Write-Host "[!] Không thể tự nâng quyền khi chạy qua iex." -ForegroundColor Red
        Write-Host "[!] Vui lòng mở PowerShell với quyền Quản trị viên (Run as Administrator) rồi chạy lại." -ForegroundColor Red
    }
    Read-Host "Nhấn ENTER để đóng"
    Exit
}

# ===================================================
# 1. HÀM QUÉT MÃ MODEL MÁY IN QUA IP THẬT (PORT 80)
# ===================================================
function Get-RicohModelFromIP {
    param ([string]$IP)
    try {
        $url = "http://$IP/web/guest/en/websys/webArch/topPage.cgi"
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 4 -ErrorAction Stop
        $htmlText = [string]$response.Content
        if ($htmlText -match '(MP\s*\d+|IMC\d+|SP\s*\d+|Aficio\s*MP\s*\d+)') {
            return ($matches[0] -replace '\s+', '')
        }
    } catch {
        # Máy in chặn cổng web hoặc lỗi kết nối
    }
    return $null
}

# ===================================================
# 2. HÀM TẢI FILE TỪ GOOGLE DRIVE (xử lý trang xác nhận)
# ===================================================
function Get-GoogleDriveFile {
    param ([string]$FileId, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ucUrl = "https://drive.google.com/uc?export=download&id=$FileId"
    $probe = "$OutFile.probe"

    Write-Host "[*] Kết nối Google Drive..." -ForegroundColor Yellow
    $resp = Invoke-WebRequest -Uri $ucUrl -UseBasicParsing -SessionVariable gdSession -OutFile $probe -TimeoutSec 60

    $fs = [System.IO.File]::OpenRead($probe)
    try { $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte() } finally { $fs.Dispose() }
    $isMZ = ($b1 -eq 0x4D -and $b2 -eq 0x5A)
    $isPK = ($b1 -eq 0x50 -and $b2 -eq 0x4B)
    Remove-Item $probe -Force

    if ($isMZ -or $isPK) {
        # Tải trực tiếp không cần xác nhận
        Invoke-WebRequest -Uri $ucUrl -UseBasicParsing -WebSession $gdSession -OutFile $OutFile -TimeoutSec 900
    } else {
        # Google Drive hiện trang xác nhận (file lớn) -> lấy token confirm
        $action = [regex]::Match($resp.Content, 'action="([^"]+)"').Groups[1].Value
        $confirm = [regex]::Match($resp.Content, 'name="(?:confirm|uuid)"[^>]*value="([^"]+)"').Groups[1].Value
        if ($action -and $confirm) {
            $dlUrl = "$action?id=$FileId&export=download&confirm=$confirm"
        } else {
            $dlUrl = "https://drive.usercontent.google.com/download?id=$FileId&export=download&confirm=t"
        }
        Invoke-WebRequest -Uri $dlUrl -UseBasicParsing -WebSession $gdSession -OutFile $OutFile -TimeoutSec 900
    }

    if (!(Test-Path $OutFile)) { throw "Không tải được file từ Google Drive" }
    $fs2 = [System.IO.File]::OpenRead($OutFile)
    try { $b1 = $fs2.ReadByte(); $b2 = $fs2.ReadByte() } finally { $fs2.Dispose() }
    if (!($b1 -eq 0x4D -and $b2 -eq 0x5A) -and !($b1 -eq 0x50 -and $b2 -eq 0x4B)) {
        throw "File tải về không phải gói driver hợp lệ"
    }
    Write-Host "[+] Tải xong: $([Math]::Round((Get-Item $OutFile).Length / 1MB, 1)) MB" -ForegroundColor Green
}

# ===================================================
# 3. HÀM GIẢI NÉN GÓI DRIVER (EXE SFX / ZIP)
# ===================================================
function Expand-DriverPackage {
    param ([string]$PackagePath, [string]$DestDir)
    $fs = [System.IO.File]::OpenRead($PackagePath)
    try { $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte() } finally { $fs.Dispose() }

    # Xóa nội dung cũ trong thư mục đích (tránh lỗi file đã tồn tại khi chạy lại)
    Get-ChildItem -Path $DestDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    if ($b1 -eq 0x4D -and $b2 -eq 0x5A) {
        # EXE tự giải nén (WinZip SFX): mở trực tiếp như ZIP bằng .NET
        Write-Host "[*] Giải nén gói driver (EXE SFX)..." -ForegroundColor Yellow
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $DestDir)
    } elseif ($b1 -eq 0x50 -and $b2 -eq 0x4B) {
        # File ZIP thường
        Write-Host "[*] Giải nén gói driver (ZIP)..." -ForegroundColor Yellow
        Expand-Archive -Path $PackagePath -DestinationPath $DestDir -Force
    } else {
        throw "Gói driver không hợp lệ"
    }

    $inf = Get-ChildItem -Path $DestDir -Recurse -Filter oemsetup.inf -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$inf) { throw "Không tìm thấy oemsetup.inf trong gói driver" }
    return $inf.FullName
}
# ===================================================
# 4. HÀM LẤY TÊN DRIVER TỪ FILE INF
# ===================================================
function Get-DriverNameFromInf {
    param ([string]$InfPath)
    $lines = Get-Content $InfPath
    foreach ($pat in @('^\s*DrvName\s*=\s*"([^"]+)"', '^\s*CoDrvName\s*=\s*"([^"]+)"')) {
        foreach ($line in $lines) {
            $m = [regex]::Match($line, $pat)
            if ($m.Success) { return $m.Groups[1].Value }
        }
    }
    return "PCL6 Driver for Universal Print"
}

# ===================================================
# 5. HÀM ĐẶT MẶC ĐỊNH KHỔ GIẤY A4 & TẮT IN 2 MẶT
# ===================================================
function Set-RicohPrinterDefaultsA4Simplex {
    param ([string]$PrinterName)
    if (-not ('RicohPrinterDefaultsCSharp' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RicohPrinterDefaultsCSharp
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PRINTER_DEFAULTS
    {
        public IntPtr pDatatype;
        public IntPtr pDevMode;
        public uint DesiredAccess;
    }

    public const uint DM_IN_BUFFER = 8;
    public const uint DM_OUT_BUFFER = 2;
    public const uint DM_MODIFY = 1;
    public const int DM_PAPERSIZE = 0x2;
    public const int DM_PAPERLENGTH = 0x4;
    public const int DM_PAPERWIDTH = 0x8;
    public const int DM_DUPLEX = 0x1000;
    public const short DMPAPER_A4 = 9;
    public const short DMDUP_SIMPLEX = 1;
    public const short A4_LENGTH_TENTH_MM = 2970;
    public const short A4_WIDTH_TENTH_MM = 2100;

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, ref PRINTER_DEFAULTS pDefault);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr hPrinter);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int DocumentProperties(IntPtr hWnd, IntPtr hPrinter, string pDeviceName, IntPtr pDevModeOutput, IntPtr pDevModeInput, uint fMode);

    public static int ApplyA4Simplex(string printerName)
    {
        PRINTER_DEFAULTS pd = new PRINTER_DEFAULTS();
        pd.DesiredAccess = 0x000F000C;

        IntPtr hPrinter;
        if (!OpenPrinter(printerName, out hPrinter, ref pd))
            return -1;

        try
        {
            int size = DocumentProperties(IntPtr.Zero, hPrinter, printerName, IntPtr.Zero, IntPtr.Zero, 0);
            if (size <= 0) return -2;

            IntPtr pIn = Marshal.AllocHGlobal(size);
            IntPtr pOut = Marshal.AllocHGlobal(size);
            try
            {
                if (DocumentProperties(IntPtr.Zero, hPrinter, printerName, pIn, IntPtr.Zero, DM_OUT_BUFFER) < 0)
                    return -3;

                int fields = Marshal.ReadInt32(pIn, 72) | DM_PAPERSIZE | DM_PAPERLENGTH | DM_PAPERWIDTH | DM_DUPLEX;
                Marshal.WriteInt32(pIn, 72, fields);
                Marshal.WriteInt16(pIn, 78, DMPAPER_A4);
                Marshal.WriteInt16(pIn, 80, A4_LENGTH_TENTH_MM);
                Marshal.WriteInt16(pIn, 82, A4_WIDTH_TENTH_MM);
                Marshal.WriteInt16(pIn, 94, DMDUP_SIMPLEX);

                int r = DocumentProperties(IntPtr.Zero, hPrinter, printerName, pOut, pIn, DM_IN_BUFFER | DM_OUT_BUFFER | DM_MODIFY);
                if (r < 0) return -4;

                int paper = Marshal.ReadInt16(pOut, 78);
                int duplex = Marshal.ReadInt16(pOut, 94);
                if (paper != DMPAPER_A4 || duplex != DMDUP_SIMPLEX)
                    return -5;
            }
            finally
            {
                Marshal.FreeHGlobal(pIn);
                Marshal.FreeHGlobal(pOut);
            }
        }
        finally
        {
            ClosePrinter(hPrinter);
        }
        return 0;
    }
}
'@
    }
    return [RicohPrinterDefaultsCSharp]::ApplyA4Simplex($PrinterName)
}

# ===================================================
# 6. CHƯƠNG TRÌNH CHÍNH (GIAO DIỆN TƯƠNG TÁC)
# ===================================================
Clear-Host
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "      CÔNG CỤ CÀI ĐẶT MÁY IN RICOH TỰ ĐỘNG         " -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""

# Nhập địa chỉ IP của máy in
$IP = Read-Host "[?] Nhập địa chỉ IP máy in (VD: 192.168.1.250)"
while ([string]::IsNullOrWhiteSpace($IP)) {
    $IP = Read-Host "[!] IP không được để trống. Nhập lại IP"
}

# ===================================================
# 6.1 KIỂM TRA MÁY IN ĐÃ CÀI SẴN CHO IP NÀY CHƯA
# ===================================================
$SkipInstall = $false
$PrinterName = ""
$DriverName = ""
$PortName = "IP_$IP"

$ExistingPrinter = Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -eq $PortName } | Select-Object -First 1

if ($ExistingPrinter) {
    Write-Host "[+] Phát hiện máy in ĐÃ CÀI SẴN cho IP ${IP}:" -ForegroundColor Green
    Write-Host "    - Tên máy in : $($ExistingPrinter.Name)"
    Write-Host "    - Driver      : $($ExistingPrinter.DriverName)"
    $Reuse = Read-Host "[?] Dùng LẠI máy in này (chỉ cập nhật cấu hình A4/User Code)? (Y/n, mặc định Y)"
    if ([string]::IsNullOrWhiteSpace($Reuse)) { $Reuse = "Y" }
    if ($Reuse -match '^[Yy]') {
        $PrinterName = $ExistingPrinter.Name
        $DriverName = $ExistingPrinter.DriverName
        $SkipInstall = $true
        Write-Host "[+] Sẽ dùng lại máy in '$PrinterName', bỏ qua bước tải và cài đặt driver." -ForegroundColor Yellow
    }
}

if (!$SkipInstall) {
    # Kết nối và kiểm tra thiết bị
    Write-Host "[*] Đang kết nối tới IP $IP để kiểm tra mã máy in..." -ForegroundColor Yellow
    $DetectedModel = Get-RicohModelFromIP -IP $IP

    if ($DetectedModel) {
        Write-Host "[+] Tìm thấy máy in Ricoh Model: $DetectedModel" -ForegroundColor Green
        $Model = $DetectedModel
    } else {
        Write-Host "[!] Không tự động quét được Model thiết bị." -ForegroundColor Red
        $Model = Read-Host "[?] Vui lòng tự nhập mã Model (Ví dụ: mp2554, imc3000)"
    }

    # Chuẩn hóa tên model: "MP2555" -> "MP 2555" (thêm khoảng trắng giữa chữ và số)
    $ModelDisplay = ($Model.ToUpper() -replace '([A-Za-z]+)(\d+)', '$1 $2')

    # Nhập tên vị trí / ghi chú do người dùng đặt, VD: "May 1", "Phong Ke Toan"
    $Label = Read-Host "[?] Nhập TÊN VỊ TRÍ / GHI CHÚ cho máy in (VD: May 1, Phong Ke Toan...) (Mặc định: '$IP')"
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = $IP }

    $DefaultPrinterName = "Ricoh $ModelDisplay ($Label)"
    $PrinterName = Read-Host "[?] Nhập TÊN MÁY IN TRÊN WINDOWS (Mặc định: '$DefaultPrinterName')"
    if ([string]::IsNullOrWhiteSpace($PrinterName)) { $PrinterName = $DefaultPrinterName }
}

# Nhập các thông tin định danh in ấn
$DefaultUser = $env:USERNAME
$UserName = Read-Host "[?] Nhập TÊN HIỂN THỊ TRÊN MÁY IN (Mặc định: '$DefaultUser')"
if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = $DefaultUser }

$UserCode = Read-Host "[?] Nhập MẬT KHẨU IN / User Code (Để trống nếu KHÔNG DÙNG Pass)"

Write-Host ""
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host " BẮT ĐẦU CẤU HÌNH HỆ THỐNG..." -ForegroundColor Green
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

# ===================================================
# 6.2 KIỂM TRA DRIVER ĐÃ CÓ TRONG HỆ THỐNG CHƯA
# ===================================================
if (!$SkipInstall -and !$DriverName) {
    $SystemDriver = Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'PCL6.*Universal' } | Select-Object -First 1
    if ($SystemDriver) {
        Write-Host "[+] Driver '$($SystemDriver.Name)' ĐÃ CÓ SẴN trong hệ thống - bỏ qua tải và cài đặt driver." -ForegroundColor Green
        $DriverName = $SystemDriver.Name
    }
}

# ===================================================
# 7. TIẾN HÀNH TẢI DRIVER - TẠO PORT - KHỞI TẠO MÁY IN
# ===================================================
$ModelLower = if ($Model) { $Model.ToLower() } else { "ricoh" }
$WorkDir = "C:\Temp\RicohInstall_$ModelLower"
$ExePath = "$WorkDir\driver.exe"

if (!(Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

# Chỉ tải và cài driver khi thật sự cần (chưa có máy in, chưa có driver)
if (!$SkipInstall -and !$DriverName) {
    # Tìm INF đã giải nén sẵn (nếu chạy lại thì không cần tải lại driver)
    $DriverPath = Get-ChildItem -Path $WorkDir -Recurse -Filter oemsetup.inf -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName }

    if (!$DriverPath) {
        Write-Host "[1/5] Đang tải bộ Driver Ricoh từ Google Drive..." -ForegroundColor Green
        try {
            Get-GoogleDriveFile -FileId $DriverFileId -OutFile $ExePath
            Write-Host "[*] Đang giải nén gói driver..." -ForegroundColor Yellow
            $DriverPath = Expand-DriverPackage -PackagePath $ExePath -DestDir $WorkDir
            if (Test-Path $ExePath) { Remove-Item $ExePath -Force }
            Write-Host "[+] Driver: $DriverPath" -ForegroundColor Green
        } catch {
            Write-Host ""
            Write-Host "[LỖI CRITICAL] Không tải hoặc không trích xuất được gói driver!" -ForegroundColor Red
            Write-Host "[CHI TIẾT LỖI]: $_" -ForegroundColor Yellow
            Write-Host ""
            Read-Host "Bấm phím ENTER để đóng công cụ..."
            return
        }
    }

    # Lấy tên driver chuẩn xác từ file INF
    $DriverName = Get-DriverNameFromInf -InfPath $DriverPath
    Write-Host "[*] Tên driver trong gói: $DriverName" -ForegroundColor Yellow

    # Đăng ký Driver vào kho hệ thống của Windows
    Write-Host "[2/5] Đang nạp Driver & Khởi tạo cổng IP mạng..." -ForegroundColor Green
    $pnputilOut = pnputil.exe /add-driver $DriverPath /install 2>&1
    $pnputilOut | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    if (!(Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue)) {
        Write-Host "[*] Đang đăng ký printer driver '$DriverName'..." -ForegroundColor Yellow
        Add-PrinterDriver -Name $DriverName -ErrorAction Stop
    }

    $DriverInstalled = Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue
    if (!$DriverInstalled) {
        Write-Host ""
        Write-Host "[LỖI CRITICAL] Không nạp được driver '$DriverName' vào hệ thống!" -ForegroundColor Red
        Read-Host "Bấm phím ENTER để đóng công cụ..."
        return
    }
    Write-Host "[+] Driver đã sẵn sàng: $DriverName" -ForegroundColor Green
}

# Tạo cổng in Standard TCP/IP Port (Mặc định chạy Port 9100 RAW)
if (!(Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue)) {
    Add-PrinterPort -Name $PortName -PrinterHostAddress $IP
}

# Khởi tạo máy in hiển thị trong Control Panel
Write-Host "[3/5] Đang tạo máy in '$PrinterName' trên hệ thống..." -ForegroundColor Green
if (!(Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) {
    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName
} else {
    Write-Host "[+] Máy in '$PrinterName' đã tồn tại - bỏ qua tạo mới." -ForegroundColor Yellow
}

# Đặt mặc định: Khổ giấy A4 + Tắt in 2 mặt (simplex)
Write-Host "[4/5] Đặt mặc định khổ giấy A4 & tắt chế độ in 2 mặt..." -ForegroundColor Green
try {
    $rc = Set-RicohPrinterDefaultsA4Simplex -PrinterName $PrinterName
    if ($rc -eq 0) {
        Write-Host "[+] Đã đặt mặc định: Khổ giấy A4, In 1 mặt (simplex)" -ForegroundColor Green
    } else {
        Write-Host "[!] Không đặt được mặc định A4/1 mặt (mã lỗi $rc). Có thể đặt thủ công trong Printing Preferences." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[!] Lỗi khi đặt mặc định A4/1 mặt: $_" -ForegroundColor Yellow
}

# Cấu hình User ID & User Code khóa mã in trong Registry Windows
Write-Host "[5/5] Thiết lập User ID và mật khẩu in (User Code)..." -ForegroundColor Green
$RegPath = "HKCU:\Software\RICOH\$DriverName\$PrinterName"
if (!(Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }

Set-ItemProperty -Path $RegPath -Name "UserID" -Value $UserName -ErrorAction SilentlyContinue
Set-ItemProperty -Path $RegPath -Name "JobOwnerName" -Value $UserName -ErrorAction SilentlyContinue

if (![string]::IsNullOrWhiteSpace($UserCode)) {
    Set-ItemProperty -Path $RegPath -Name "UserCode" -Value $UserCode -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RegPath -Name "AuthMode" -Value 1 -ErrorAction SilentlyContinue
} else {
    Set-ItemProperty -Path $RegPath -Name "UserCode" -Value "" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RegPath -Name "AuthMode" -Value 0 -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "    [✔] CHÚC MỪNG! MÁY IN ĐÃ ĐƯỢC CÀI ĐẶT THÀNH CÔNG!   " -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[THÔNG TIN]"
Write-Host "  - Tên máy in : $PrinterName"
Write-Host "  - Driver      : $DriverName"
Write-Host "  - Cổng        : $PortName"
Write-Host "  - Giấy mặc định: A4"
Write-Host "  - In 2 mặt     : Đã tắt (1 mặt)"
Write-Host ""
Read-Host "Bấm phím ENTER để đóng công cụ..."
