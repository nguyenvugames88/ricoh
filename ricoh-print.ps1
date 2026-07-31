# ===================================================
# 0. TỰ ĐỘNG KIỂM TRA VÀ NÂNG QUYỀN ADMINISTRATOR
# ===================================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[*] Thống đang yêu cầu quyền Quản trị (Admin)..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# ===================================================
# 1. HÀM TỰ ĐỘNG QUÉT MÃ MODEL MÁY IN QUA IP THẬT (PORT 80)
# ===================================================
function Get-RicohModelFromIP {
    param ([string]$IP)
    try {
        # Sử dụng Port 80 mặc định của máy in Ricoh thật
        $url = "http://$IP/web/guest/en/websys/webArch/topPage.cgi"
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 4 -ErrorAction Stop
        
        # Ép kiểu dữ liệu HTML về dạng chuỗi văn bản thuần
        $htmlText = [string]$response.Content
        
        # Biểu thức Regex quét mã máy in Ricoh (MP, IMC, SP, Aficio MP...)
        if ($htmlText -match '(MP\s*\d+|IMC\d+|SP\s*\d+|Aficio\s*MP\s*\d+)') {
            # Lấy chính xác chuỗi khớp đầu tiên và xóa bỏ khoảng trắng
            $model = $matches[0] -replace '\s+', ''
            return $model
        }
    } catch {
        # Khối dự phòng nếu máy in chặn cổng Web hoặc lỗi kết nối
    }
    return $null
}

# ===================================================
# 2. CHƯƠNG TRÌNH CHÍNH (GIAO DIỆN TƯƠNG TÁC)
# ===================================================
Clear-Host
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "      CÔNG CỤ CÀI ĐẶT MÁY IN RICOH TỰ ĐỘNG         " -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""

# Nhập địa chỉ IP của máy in thực tế
$IP = Read-Host "[?] Nhập địa chỉ IP máy in (VD: 192.168.1.250)"
while ([string]::IsNullOrWhiteSpace($IP)) {
    $IP = Read-Host "[!] IP không được để trống. Nhập lại IP"
}

# Tiến hành kết nối và kiểm tra thiết bị qua mạng nội bộ
Write-Host "[*] Đang kết nối tới IP $IP để kiểm tra mã máy in..." -ForegroundColor Yellow
$DetectedModel = Get-RicohModelFromIP -IP $IP

if ($DetectedModel) {
    Write-Host "[+] Tìm thấy máy in Ricoh Model: $DetectedModel" -ForegroundColor Green
    $Model = $DetectedModel
} else {
    Write-Host "[!] Không tự động quét được Model thiết bị." -ForegroundColor Red
    $Model = Read-Host "[?] Vui lòng tự nhập mã Model (Ví dụ: mp2554, imc3000)"
}

# Nhập các thông tin định danh in ấn
$DefaultUser = $env:USERNAME
$UserName = Read-Host "[?] Nhập TÊN HIỂN THỊ TRÊN MÁY IN (Mặc định: '$DefaultUser')"
if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = $DefaultUser }

$UserCode = Read-Host "[?] Nhập MẬT KHẨU IN / User Code (Để trống nếu KHÔNG DÙNG Pass)"

$DefaultPrinterName = "Ricoh $($Model.ToUpper()) ($IP)"
$PrinterName = Read-Host "[?] Nhập TÊN MÁY IN TRÊN WINDOWS (Mặc định: '$DefaultPrinterName')"
if ([string]::IsNullOrWhiteSpace($PrinterName)) { $PrinterName = $DefaultPrinterName }

Write-Host ""
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host " BẮT ĐẦU CẤU HÌNH HỆ THỐNG..." -ForegroundColor Green
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

# ===================================================
# 3. TIẾN HÀNH TẢI DRIVER - TẠO PORT - KHỞI TẠO MÁY IN
# ===================================================
$ModelLower  = $Model.ToLower()

# !!! HÃY THAY LINK TINYURL CHỨA FILE DRIVER ZIP THẬT CỦA BẠN VÀO ĐÂY !!!
$DriverUrl   = "https://tinyurl.com" 
$DriverName  = "RICOH PCL6 UniversalDriver V4.35"
$WorkDir     = "C:\Temp\RicohInstall_$ModelLower"
$DriverPath  = "$WorkDir\oem-setup.inf"

# Tự động tạo thư mục tạm và tải Driver từ Cloud
if (!(Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }
$zipPath = "$WorkDir\driver.zip"

if (!(Test-Path $DriverPath)) {
    Write-Host "[1/4] Đang tải bộ Driver cho dòng $Model từ Server..." -ForegroundColor Green
    try {
        Invoke-WebRequest -Uri $DriverUrl -OutFile $zipPath -ErrorAction Stop
        Expand-Archive -Path $zipPath -DestinationPath $WorkDir -Force
    } catch {
        Write-Host "[LỖI CRITICAL] Không tải được gói driver! Vui lòng kiểm tra lại liên kết mạng hoặc file zip." -ForegroundColor Red
        Exit
    }
}

# Đăng ký Driver vào kho hệ thống của Windows
Write-Host "[2/4] Đang nạp Driver & Khởi tạo cổng IP mạng..." -ForegroundColor Green
pnputil.exe /add-driver $DriverPath /install | Out-Null

# Tạo cổng in Standard TCP/IP Port kết nối tới IP máy in (Mặc định chạy Port 9100 RAW)
$PortName = "IP_$IP"
if (!(Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue)) {
    Add-PrinterPort -Name $PortName -PrinterHostAddress $IP
}

# Khởi tạo máy in hiển thị trong Control Panel
Write-Host "[3/4] Đang tạo máy in '$PrinterName' trên hệ thống..." -ForegroundColor Green
if (!(Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) {
    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName
}

# Cấu hình User ID & User Code khóa mã in trong Registry Windows
Write-Host "[4/4] Thiết lập User ID và mật khẩu in (User Code)..." -ForegroundColor Green
$RegPath = "HKCU:\Software\RICOH\RICOH PCL6 UniversalDriver V4.35\$PrinterName"
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

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "    [✔] CHÚC MỪNG! MÁY IN ĐÃ ĐƯỢC CÀI ĐẶT THÀNH CÔNG!   " -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Cyan
