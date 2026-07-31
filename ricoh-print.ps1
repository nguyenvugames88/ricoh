# ===================================================
# HÀM TỰ ĐỘNG QUÉT MÃ MODEL MÁY IN QUA IP
# ===================================================
function Get-RicohModelFromIP {
    param ([string]$IP)
    try {
        # Kết nối tới Server giả lập qua cổng 8080
        $url = "http://$IP:8080/web/guest/en/websys/webArch/topPage.cgi"
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 3 -ErrorAction Stop
        
        # Chuyển đổi nội dung HTML về dạng chuỗi thuần túy
        $htmlText = [string]$response.Content
        
        # [DEBUG] In thử nội dung quét được để bạn kiểm tra xem IP đã giả lập thành công chưa
        Write-Host "[DEBUG] HTML nhan duoc: $htmlText" -ForegroundColor DarkGray
        
        # Biểu thức Regex quét mã máy in Ricoh
        if ($htmlText -match '(MP\s*\d+|IMC\d+|SP\s*\d+|Aficio\s*MP\s*\d+)') {
            # SỬA LỖI: Bắt buộc phải là $matches[0] để lấy chuỗi tìm thấy
            $model = $matches[0] -replace '\s+', ''
            return $model
        }
    } catch {
        Write-Host "[DEBUG] Loi ket noi toi IP: $_" -ForegroundColor DarkGray
    }
    return $null
}

# ===================================================
# CHƯƠNG TRÌNH CHÍNH (INTERACTIVE MENU)
# ===================================================
Clear-Host
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "      CÔNG CỤ CÀI ĐẶT MÁY IN RICOH TỰ ĐỘNG         " -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Yêu cầu nhập IP
$IP = Read-Host "[?] Nhập địa chỉ IP máy in"
while ([string]::IsNullOrWhiteSpace($IP)) {
    $IP = Read-Host "[!] IP không được để trống. Nhập lại IP"
}

# 2. Tự động check Model từ IP
Write-Host "[*] Đang kết nối tới IP $IP để kiểm tra mã máy in..." -ForegroundColor Yellow
$DetectedModel = Get-RicohModelFromIP -IP $IP

if ($DetectedModel) {
    Write-Host "[+] Tìm thấy máy in Ricoh Model: $DetectedModel" -ForegroundColor Green
    $Model = $DetectedModel
} else {
    Write-Host "[!] Không tự động quét được Model." -ForegroundColor Red
    $Model = Read-Host "[?] Vui lòng tự nhập mã Model (Ví dụ: mp2554, mp3054)"
}

# Các bước cài đặt phía sau giữ nguyên...
Write-Host "[*] Model duoc chon de tiep tuc setup: $Model" -ForegroundColor Cyan


# 3. Yêu cầu nhập Tên hiển thị trên máy in
$DefaultUser = $env:USERNAME
$UserName = Read-Host "[?] Nhập TÊN HIỂN THỊ TRÊN MÁY IN (Mặc định: '$DefaultUser')"
if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = $DefaultUser }

# 4. Yêu cầu nhập Pass in / User Code
$UserCode = Read-Host "[?] Nhập MẬT KHẨU IN / User Code (Để trống nếu KHÔNG DÙNG Pass)"

# 5. Yêu cầu nhập Tên máy in hiển thị trên Windows
$DefaultPrinterName = "Ricoh $($Model.ToUpper()) ($IP)"
$PrinterName = Read-Host "[?] Nhập TÊN MÁY IN TRÊN MÁY TÍNH (Mặc định: '$DefaultPrinterName')"
if ([string]::IsNullOrWhiteSpace($PrinterName)) { $PrinterName = $DefaultPrinterName }

Write-Host ""
Write-Host "---------------------------------------------------" -ForegroundColor Cyan
Write-Host " BẮT ĐẦU CÀI ĐẶT..." -ForegroundColor Green
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

# ===================================================
# TIẾN HÀNH CÀI ĐẶT DRIVER & MÁY IN
# ===================================================
$ModelLower  = $Model.ToLower()
# Thay liên kết TinyURL chứa file Driver zip trực tiếp từ GitHub của bạn vào đây
$DriverUrl   = "https://tinyurl.com" 
$DriverName  = "RICOH PCL6 UniversalDriver V4.35"
$WorkDir     = "C:\Temp\RicohInstall_$ModelLower"
$DriverPath  = "$WorkDir\oem-setup.inf"

# Tải và giải nén Driver
if (!(Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }
$zipPath = "$WorkDir\driver.zip"

if (!(Test-Path $DriverPath)) {
    Write-Host "[1/4] Đang tải bộ Driver $Model từ server..." -ForegroundColor Green
    try {
        Invoke-WebRequest -Uri $DriverUrl -OutFile $zipPath -ErrorAction Stop
        Expand-Archive -Path $zipPath -DestinationPath $WorkDir -Force
    } catch {
        Write-Host "[LỖI CRITICAL] Không tải được driver cho '$Model'! Kiểm tra lại file zip hoặc liên kết TinyURL." -ForegroundColor Red
        Exit
    }
}

# Nạp Driver & Tạo Port IP
Write-Host "[2/4] Cấu hình Driver & Port IP..." -ForegroundColor Green
pnputil.exe /add-driver $DriverPath /install | Out-Null

$PortName = "IP_$IP"
if (!(Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue)) {
    Add-PrinterPort -Name $PortName -PrinterHostAddress $IP
}

# Tạo Máy in
Write-Host "[3/4] Tạo máy in '$PrinterName'..." -ForegroundColor Green
if (!(Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) {
    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName
}

# Cấu hình User ID & User Code trong Registry Windows
Write-Host "[4/4] Lưu định danh người dùng & Pass in..." -ForegroundColor Green
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
Write-Host "       [✔] CÀI ĐẶT HOÀN TẤT THÀNH CÔNG!            " -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Cyan
