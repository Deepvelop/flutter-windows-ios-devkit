# Flutter iOS DevKit - Complete Installer
# Windows -> Mac remote iOS build & deployment

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# Check if running as administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host "❌ This installer requires administrator privileges!" -ForegroundColor Red
    Write-Host "💡 Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
    Write-Host "   Right-click PowerShell → 'Run as Administrator'" -ForegroundColor Cyan
    exit 1
}

Write-Host "\n🧰 Flutter iOS DevKit Complete Installer (Windows -> Mac)\n" -ForegroundColor Cyan
Write-Host "🛡️  Running with Administrator privileges" -ForegroundColor Green

# === Collect Info ===
try {
    Write-Host "\n📝 Collecting configuration information..." -ForegroundColor Cyan
    $macIP = Read-Host "🔌 Enter your Mac IP address"
    if ([string]::IsNullOrWhiteSpace($macIP)) {
        throw "Mac IP address cannot be empty"
    }
    
    $macUser = Read-Host "👤 Enter your Mac username"
    if ([string]::IsNullOrWhiteSpace($macUser)) {
        throw "Mac username cannot be empty"
    }
    
    $apiKey = Read-Host "🔑 Enter your Apple API Key (for TestFlight)"
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Apple API Key cannot be empty"
    }
    
    $apiIssuer = Read-Host "🏢 Enter your Apple API Issuer ID"
    if ([string]::IsNullOrWhiteSpace($apiIssuer)) {
        throw "Apple API Issuer ID cannot be empty"
    }
    
    $targetDir = "/Users/$macUser/Dev/iOS"
    $sshKeyPath = "$env:USERPROFILE\.ssh\id_rsa"
    
    Write-Host "✅ Configuration collected successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error collecting configuration: $_" -ForegroundColor Red
    exit 1
}

# === SSH Key ===
try {
    Write-Host "\n🔐 Setting up SSH authentication..." -ForegroundColor Cyan
    
    if (!(Test-Path "$sshKeyPath.pub")) {
        Write-Host "🔐 Generating SSH Key..."
        $sshResult = ssh-keygen -t rsa -b 4096 -f $sshKeyPath -N ""
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to generate SSH key"
        }
    } else {
        Write-Host "✅ SSH key already exists" -ForegroundColor Green
    }

    Write-Host "🚀 Copying SSH Key to Mac..."
    $copyResult = ssh-copy-id "$macUser@$macIP"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy SSH key to Mac. Please check your Mac IP and username."
    }
    
    Write-Host "✅ SSH authentication configured successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error setting up SSH: $_" -ForegroundColor Red
    Write-Host "💡 Make sure SSH is enabled on your Mac and the IP/username are correct" -ForegroundColor Yellow
    exit 1
}

# === Setup Remote Mac ===
try {
    Write-Host "\n🍎 Setting up Mac environment..." -ForegroundColor Cyan
    
    $macSetupScript = @"
#!/bin/bash
set -e

mkdir -p "$targetDir"
cd "$targetDir"

# Install Homebrew if missing
if ! command -v brew &> /dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "`$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install Flutter only if missing
if ! command -v flutter &> /dev/null; then
  echo "Installing Flutter..."
  brew install --cask flutter
fi

# Install Fastlane only if missing
if ! command -v fastlane &> /dev/null; then
  echo "Installing Fastlane..."
  brew install fastlane
fi

# Install Xcode command line tools if needed
if ! xcode-select -p &> /dev/null; then
  echo "Installing Xcode command line tools..."
  xcode-select --install || true
fi

# Setup Fastlane template
mkdir -p fastlane
cat > fastlane/Fastfile <<EOL
platform :ios do
  desc "Push to TestFlight"
  lane :beta do
    build_app(scheme: ENV['SCHEME'])
    upload_to_testflight(api_key: {
      key_id: "$apiKey",
      issuer_id: "$apiIssuer",
      key_content: File.read(ENV['HOME'] + "/.appstoreconnect/private_keys/AuthKey_$apiKey.p8")
    })
  end
end
EOL
"@

    $tempScript = "$env:TEMP\mac_setup.sh"
    Set-Content $tempScript -Value $macSetupScript -Encoding UTF8
    
    $scpResult = scp $tempScript "${macUser}@${macIP}:/tmp/mac_setup.sh"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy setup script to Mac"
    }
    
    $sshResult = ssh "$macUser@$macIP" "chmod +x /tmp/mac_setup.sh && /tmp/mac_setup.sh"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to execute setup script on Mac"
    }
    
    Write-Host "✅ Mac environment setup completed" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error setting up Mac environment: $_" -ForegroundColor Red
    Write-Host "💡 Make sure your Mac has internet connection and proper permissions" -ForegroundColor Yellow
    exit 1
}

# === Upload deploy-helper.sh ===
try {
    Write-Host "\n📦 Installing deployment helper..." -ForegroundColor Cyan
    
    $deployScript = @"
#!/bin/bash
set -e

APP_PATH=`$(basename "`$PWD")
LAST_HASH_FILE=".last_pubspec_hash"

if [ -f `$LAST_HASH_FILE ]; then
  LAST_HASH=`$(cat `$LAST_HASH_FILE)
else
  LAST_HASH=""
fi
CURRENT_HASH=`$(find pubspec.yaml pubspec.lock assets -type f -exec md5sum {} + 2>/dev/null | md5sum | cut -d ' ' -f1)

if [[ "`$CURRENT_HASH" != "`$LAST_HASH" ]]; then
  echo "[🔁] Changes detected. Cleaning..."
  flutter clean
  flutter pub get
  echo `$CURRENT_HASH > `$LAST_HASH_FILE
else
  echo "[✅] No changes in dependencies."
fi

case "`$1" in
  run)
    flutter run
    ;;
  build)
    flutter build ios
    ;;
  archive)
    xcodebuild -workspace ios/Runner.xcworkspace -scheme `$APP_PATH -sdk iphoneos -configuration Release archive -archivePath "`$HOME/Archives/`$APP_PATH.xcarchive"
    ;;
  validate)
    xcrun altool --validate-app -f "`$HOME/Archives/`$APP_PATH.xcarchive/Products/Applications/Runner.app" -t ios --apiKey $apiKey --apiIssuer $apiIssuer
    ;;
  upload)
    xcrun altool --upload-app -f "`$HOME/Archives/`$APP_PATH.xcarchive/Products/Applications/Runner.app" -t ios --apiKey $apiKey --apiIssuer $apiIssuer
    ;;
  *)
    echo "[❓] Unknown command: `$1"
    ;;
esac
"@

    $tempDeploy = "$env:TEMP\deploy-helper.sh"
    Set-Content -Path $tempDeploy -Value $deployScript -Encoding UTF8
    
    $scpResult = scp $tempDeploy "${macUser}@${macIP}:${targetDir}/deploy-helper.sh"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy deploy helper to Mac"
    }
    
    $sshResult = ssh "$macUser@$macIP" "chmod +x $targetDir/deploy-helper.sh"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set execute permissions on deploy helper"
    }
    
    Write-Host "✅ Deployment helper installed successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error installing deployment helper: $_" -ForegroundColor Red
    exit 1
}

# === Install ios-cli.ps1 globally ===
try {
    Write-Host "\n⚙️  Installing global CLI tool..." -ForegroundColor Cyan
    
    $cliPath = "$env:USERPROFILE\flutter-ios-cli"
    New-Item -ItemType Directory -Force -Path $cliPath | Out-Null

    $cliScript = @"
param(
  [string] `$Command = "",
  [string[]] `$Args
)

try {
    `$config = Get-Content "`$PSScriptRoot\.ios-devkit-config.json" | ConvertFrom-Json
    `$macUser = `$config.MacUser
    `$macIP = `$config.MacIP
    `$targetDir = `$config.TargetDir
}
catch {
    Write-Host "[❌] Error reading configuration: `$_" -ForegroundColor Red
    Write-Host "💡 Please run the installer again to fix configuration issues." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path "pubspec.yaml")) {
  if (`$Command -ne "init") {
    Write-Host "[❌] No Flutter project found in this directory." -ForegroundColor Red
    Write-Host "💡 Tip: Use 'flutter-ios init' to set up a new project."
    exit 1
  }
}

try {
    switch (`$Command) {
      "run" { 
        `$projectName = (Get-Item .).Name
        Write-Host "🏃 Running Flutter app on iOS device..." -ForegroundColor Yellow
        ssh "`$macUser@`$macIP" "cd `$targetDir/`$projectName && ./deploy-helper.sh run" 
      }
      "build" { 
        `$projectName = (Get-Item .).Name
        Write-Host "🔨 Building iOS app..." -ForegroundColor Yellow
        ssh "`$macUser@`$macIP" "cd `$targetDir/`$projectName && ./deploy-helper.sh build" 
      }
      "archive" { 
        `$projectName = (Get-Item .).Name
        Write-Host "📦 Creating iOS archive..." -ForegroundColor Yellow
        ssh "`$macUser@`$macIP" "cd `$targetDir/`$projectName && ./deploy-helper.sh archive" 
      }
      "validate" { 
        `$projectName = (Get-Item .).Name
        Write-Host "✅ Validating app with App Store..." -ForegroundColor Yellow
        ssh "`$macUser@`$macIP" "cd `$targetDir/`$projectName && ./deploy-helper.sh validate" 
      }
      "upload" { 
        `$projectName = (Get-Item .).Name
        Write-Host "🚀 Uploading to TestFlight..." -ForegroundColor Yellow
        ssh "`$macUser@`$macIP" "cd `$targetDir/`$projectName && ./deploy-helper.sh upload" 
      }
      "sync" {
        `$projectName = (Get-Item .).Name
        Write-Host "🔄 Syncing project files to Mac..." -ForegroundColor Yellow
        rsync -avz --delete --exclude '.git' --exclude 'build' --exclude '.dart_tool' . "`$macUser@`$macIP:`$targetDir/`$projectName/"
        Write-Host "✅ Project synced to Mac" -ForegroundColor Green
      }
      "init" {
        `$gitUrl = Read-Host "🌐 Enter Git URL of Flutter project (or press Enter to sync current directory)"
        if ([string]::IsNullOrWhiteSpace(`$gitUrl)) {
          # Sync current directory
          if (-not (Test-Path "pubspec.yaml")) {
            Write-Host "[❌] No Flutter project found in current directory." -ForegroundColor Red
            exit 1
          }
          `$projectName = (Get-Item .).Name
          Write-Host "🔄 Creating project directory on Mac and syncing files..." -ForegroundColor Yellow
          ssh "`$macUser@`$macIP" "mkdir -p `$targetDir/`$projectName"
          rsync -avz --exclude '.git' --exclude 'build' --exclude '.dart_tool' . "`$macUser@`$macIP:`$targetDir/`$projectName/"
          ssh "`$macUser@`$macIP" "cd `$targetDir/`$projectName && cp ../deploy-helper.sh . && chmod +x deploy-helper.sh"
          Write-Host "✅ Project initialized and synced to Mac" -ForegroundColor Green
        } else {
          # Clone from Git
          `$projectName = [System.IO.Path]::GetFileNameWithoutExtension(`$gitUrl)
          if (`$projectName.EndsWith('.git')) {
            `$projectName = `$projectName.Substring(0, `$projectName.Length - 4)
          }
          Write-Host "📦 Cloning project to Mac..." -ForegroundColor Yellow
          ssh "`$macUser@`$macIP" "cd `$targetDir && git clone `$gitUrl"
          ssh "`$macUser@`$macIP" "cd `$targetDir/`$projectName && cp ../deploy-helper.sh . && chmod +x deploy-helper.sh"
          Write-Host "✅ Project cloned and initialized on Mac" -ForegroundColor Green
        }
      }
      default {
        Write-Host "[❓] Unknown or missing command. Available commands:" -ForegroundColor Yellow
        Write-Host "  init   - Initialize project (clone from Git or sync current directory)"
        Write-Host "  sync   - Sync current project files to Mac"
        Write-Host "  run    - Run Flutter app on connected iOS device"
        Write-Host "  build  - Build iOS app"
        Write-Host "  archive- Create archive for App Store"
        Write-Host "  validate - Validate app with App Store"
        Write-Host "  upload - Upload app to TestFlight"
      }
    }
}
catch {
    Write-Host "[❌] Error executing command: `$_" -ForegroundColor Red
    Write-Host "💡 Check your Mac connection and try again." -ForegroundColor Yellow
    exit 1
}
"@

    $cliScriptPath = "$cliPath\ios-cli.ps1"
    Set-Content $cliScriptPath -Value $cliScript -Encoding UTF8
    
    Write-Host "✅ CLI tool installed successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error installing CLI tool: $_" -ForegroundColor Red
    exit 1
}

# === Add to PowerShell Profile ===
try {
    Write-Host "\n🔧 Configuring PowerShell profile..." -ForegroundColor Cyan
    
    $profilePath = "$PROFILE.CurrentUserAllHosts"
    
    # Create profile directory if it doesn't exist
    $profileDir = Split-Path $profilePath -Parent
    if (!(Test-Path $profileDir)) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }
    
    # Create profile file if it doesn't exist
    if (!(Test-Path $profilePath)) {
        New-Item -ItemType File -Force -Path $profilePath | Out-Null
    }
    
    $profileContent = Get-Content $profilePath -ErrorAction SilentlyContinue
    if (!($profileContent | Select-String -Pattern "flutter-ios")) {
        Add-Content $profilePath "`nfunction flutter-ios { PowerShell -File `"$cliScriptPath`" @args }"
        Write-Host "💡 Run 'flutter-ios' from any PowerShell window after restarting your terminal."
    }
    
    Write-Host "✅ PowerShell profile configured successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error configuring PowerShell profile: $_" -ForegroundColor Red
    Write-Host "💡 You may need to manually add the flutter-ios function to your profile" -ForegroundColor Yellow
}

# === Save Config ===
try {
    Write-Host "\n💾 Saving configuration..." -ForegroundColor Cyan
    
    $config = @{
        MacIP = $macIP
        MacUser = $macUser
        APIKey = $apiKey
        APIIssuer = $apiIssuer
        TargetDir = $targetDir
    }
    $config | ConvertTo-Json | Out-File -Encoding UTF8 "$cliPath\.ios-devkit-config.json"
    
    Write-Host "✅ Configuration saved successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error saving configuration: $_" -ForegroundColor Red
    exit 1
}

Write-Host "\n🎉 Flutter iOS DevKit Installation Completed Successfully!" -ForegroundColor Green
Write-Host "📝 Available commands: init, sync, run, build, archive, validate, upload" -ForegroundColor Cyan
Write-Host "🚀 Use 'flutter-ios' command to control your Mac from Windows!" -ForegroundColor Cyan
Write-Host "💡 Restart your PowerShell terminal to use the new commands." -ForegroundColor Yellow 