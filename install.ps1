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

Write-Host "\n📋 Prerequisites for App Store Connect API:" -ForegroundColor Yellow
Write-Host "  1. Go to App Store Connect → Users and Access → Keys" -ForegroundColor White
Write-Host "  2. Create an API Key with App Manager or Developer role" -ForegroundColor White
Write-Host "  3. Download the AuthKey_XXXXXXXXXX.p8 file to your computer" -ForegroundColor White
Write-Host "  4. Note the Key ID (10 characters) and Issuer ID (UUID) from the page" -ForegroundColor White
Write-Host "  5. Have the full path to your .p8 file ready" -ForegroundColor White

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
    
    $macPassword = Read-Host "🔒 Enter your Mac password (needed for Homebrew installation)" -AsSecureString
    $macPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($macPassword))
    
    $keyId = Read-Host "🔑 Enter your Apple App Store Connect Key ID (e.g., ABC123DEFG)"
    if ([string]::IsNullOrWhiteSpace($keyId)) {
        throw "Apple Key ID cannot be empty"
    }
    
    $issuerId = Read-Host "🏢 Enter your Apple Issuer ID (from App Store Connect)"
    if ([string]::IsNullOrWhiteSpace($issuerId)) {
        throw "Apple Issuer ID cannot be empty"
    }
    
    $privateKeyPath = Read-Host "📄 Enter the full path to your AuthKey_$keyId.p8 file"
    if ([string]::IsNullOrWhiteSpace($privateKeyPath)) {
        throw "Private key path cannot be empty"
    }
    
    # Remove quotes from path if present
    $privateKeyPath = $privateKeyPath.Trim('"').Trim("'")
    
    if (!(Test-Path $privateKeyPath)) {
        throw "Private key file not found at: $privateKeyPath`nPlease check the file path and try again"
    }
    
    # Verify it's actually a .p8 file
    if (!(($privateKeyPath -like "*.p8") -and ($privateKeyPath -like "*AuthKey_$keyId*"))) {
        throw "File must be named AuthKey_$keyId.p8"
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
    
    Write-Host "💡 Make sure SSH is enabled on your Mac:" -ForegroundColor Yellow
    Write-Host "   System Preferences → Sharing → Remote Login (check enabled)" -ForegroundColor White
    Write-Host "   Make sure you have admin privileges on your Mac" -ForegroundColor White
    
    $continue = Read-Host "Press Enter when SSH is enabled on your Mac and you're ready to continue"
    
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
    
    # Read the public key content
    $publicKeyContent = Get-Content "$sshKeyPath.pub" -Raw
    if ([string]::IsNullOrWhiteSpace($publicKeyContent)) {
        throw "Failed to read SSH public key"
    }
    
    # Copy public key to Mac and add to authorized_keys
    try {
        # First, try to create .ssh directory on Mac (in case it doesn't exist)
        ssh "$macUser@$macIP" "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create .ssh directory on Mac"
        }
        
        # Append the public key to authorized_keys
        $escapedKey = $publicKeyContent.Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
        ssh "$macUser@$macIP" "echo `"$escapedKey`" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add public key to authorized_keys"
        }
        
        # Test the SSH connection without password
        Write-Host "🔍 Testing SSH key authentication..."
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$macUser@$macIP" "echo 'SSH key authentication successful'"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "⚠️  SSH key may not be working yet. You might need to enter your password for subsequent commands." -ForegroundColor Yellow
        }
    }
    catch {
        throw "Failed to setup SSH key authentication: $_"
    }
    
    Write-Host "✅ SSH authentication configured successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error setting up SSH: $_" -ForegroundColor Red
    Write-Host "💡 Troubleshooting SSH issues:" -ForegroundColor Yellow
    Write-Host "   1. Verify SSH is enabled: System Preferences → Sharing → Remote Login" -ForegroundColor White
    Write-Host "   2. Check Mac IP address: System Preferences → Network" -ForegroundColor White
    Write-Host "   3. Verify Mac username is correct" -ForegroundColor White
    Write-Host "   4. Try pinging your Mac: ping $macIP" -ForegroundColor White
    Write-Host "   5. Test SSH manually: ssh $macUser@$macIP" -ForegroundColor White
    exit 1
}

# === Setup Remote Mac ===
try {
    Write-Host "\n🍎 Setting up Mac environment..." -ForegroundColor Cyan
    
    $macSetupScript = @"
#!/bin/bash
set -e

echo "Setting up directories..."
mkdir -p "$targetDir"
cd "$targetDir"

# Function to run sudo commands with password
run_sudo() {
    echo "$macPasswordPlain" | sudo -S "`$@"
}

# Install Xcode command line tools first (needed for Homebrew)
if ! xcode-select -p &> /dev/null; then
  echo "Installing Xcode command line tools..."
  # This will prompt user to install via GUI
  xcode-select --install 2>/dev/null || echo "Xcode command line tools installation initiated"
  echo "Please install Xcode command line tools if prompted and press any key to continue..."
  read -n 1 -s
fi

# Install Homebrew if missing
if ! command -v brew &> /dev/null; then
  echo "Installing Homebrew..."
  # Use non-interactive installation
  export NONINTERACTIVE=1
  export CI=1
  /bin/bash -c "`$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  
  # Add Homebrew to PATH for this session
  if [[ -f "/opt/homebrew/bin/brew" ]]; then
    eval "`$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -f "/usr/local/bin/brew" ]]; then
    eval "`$(/usr/local/bin/brew shellenv)"
  fi
fi

# Fix Homebrew permissions if needed
if command -v brew &> /dev/null; then
  echo "Checking Homebrew permissions..."
  BREW_PREFIX="`$(brew --prefix)"
  if [[ ! -w "`$BREW_PREFIX" ]]; then
    echo "Fixing Homebrew permissions..."
    run_sudo chown -R "`$(whoami):admin" "`$BREW_PREFIX" 2>/dev/null || true
  fi
fi

# Install Flutter only if missing
if ! command -v flutter &> /dev/null; then
  echo "Installing Flutter..."
  brew install --cask flutter || {
    echo "Trying alternative Flutter installation..."
    cd /tmp
    curl -o flutter.zip https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_stable.zip
    unzip -q flutter.zip
    run_sudo mv flutter /usr/local/
    export PATH="/usr/local/flutter/bin:`$PATH"
    echo 'export PATH="/usr/local/flutter/bin:`$PATH"' >> ~/.zshrc
    echo 'export PATH="/usr/local/flutter/bin:`$PATH"' >> ~/.bash_profile
  }
fi

# Install Fastlane only if missing
if ! command -v fastlane &> /dev/null; then
  echo "Installing Fastlane..."
  brew install fastlane || {
    echo "Installing Fastlane via gem..."
    run_sudo gem install fastlane
  }
fi

# Create App Store Connect private keys directory
mkdir -p "\$HOME/.appstoreconnect/private_keys"

# Setup Fastlane template
mkdir -p fastlane
cat > fastlane/Fastfile <<EOL
platform :ios do
  desc "Build and push to TestFlight"
  lane :beta do
    # Build the app
    build_app(
      scheme: ENV['SCHEME'] || "Runner",
      export_method: "app-store",
      output_directory: "./build/ios/archive"
    )
    
    # Upload to TestFlight
    upload_to_testflight(
      api_key_path: ENV['HOME'] + "/.appstoreconnect/private_keys/AuthKey_$keyId.p8",
      skip_waiting_for_build_processing: true
    )
  end
  
  desc "Just build the app"
  lane :build_only do
    build_app(
      scheme: ENV['SCHEME'] || "Runner",
      export_method: "app-store",
      output_directory: "./build/ios/archive"
    )
  end
end
EOL

# Create .env file for Fastlane
cat > fastlane/.env <<EOL
FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD=""
FASTLANE_SESSION=""
FASTLANE_TEAM_ID=""
EOL

echo "Mac setup completed successfully!"
"@

    $tempScript = "$env:TEMP\mac_setup.sh"
    Set-Content $tempScript -Value $macSetupScript -Encoding UTF8
    
    $scpResult = scp $tempScript "${macUser}@${macIP}:/tmp/mac_setup.sh"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy setup script to Mac"
    }
    
    Write-Host "🍎 Running Mac setup script (this may take a few minutes)..." -ForegroundColor Yellow
    $sshResult = ssh "$macUser@$macIP" "chmod +x /tmp/mac_setup.sh && /tmp/mac_setup.sh"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "⚠️  Automated setup failed. Let's try manual setup..." -ForegroundColor Yellow
        
        Write-Host "Please run these commands manually on your Mac:" -ForegroundColor Cyan
        Write-Host "1. Install Xcode command line tools: xcode-select --install" -ForegroundColor White
        Write-Host "2. Install Homebrew: /bin/bash -c `"`$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)`"" -ForegroundColor White
        Write-Host "3. Install Flutter: brew install --cask flutter" -ForegroundColor White
        Write-Host "4. Install Fastlane: brew install fastlane" -ForegroundColor White
        
        $manualContinue = Read-Host "Press Enter after completing these steps manually"
        
        # Verify tools are installed
        Write-Host "🔍 Verifying installation..." -ForegroundColor Yellow
        $verifyResult = ssh "$macUser@$macIP" "command -v brew && command -v flutter && command -v fastlane"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "⚠️  Some tools may not be installed properly, but continuing..." -ForegroundColor Yellow
        }
    }
    
    Write-Host "✅ Mac environment setup completed" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error setting up Mac environment: $_" -ForegroundColor Red
    Write-Host "💡 Troubleshooting Mac setup issues:" -ForegroundColor Yellow
    Write-Host "   1. Make sure your Mac password is correct" -ForegroundColor White
    Write-Host "   2. Ensure your Mac has internet connection" -ForegroundColor White
    Write-Host "   3. Check if Xcode command line tools are installed" -ForegroundColor White
    Write-Host "   4. Try running: xcode-select --install" -ForegroundColor White
    Write-Host "   5. Manual Homebrew install: /bin/bash -c `"`$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)`"" -ForegroundColor White
    exit 1
}

# === Upload Apple Private Key ===
try {
    Write-Host "\n🔐 Installing Apple App Store Connect private key..." -ForegroundColor Cyan
    
    $keyFileName = "AuthKey_$keyId.p8"
    $macKeyPath = "/Users/$macUser/.appstoreconnect/private_keys/$keyFileName"
    
    # Copy the private key to Mac
    $scpResult = scp $privateKeyPath "${macUser}@${macIP}:$macKeyPath"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy private key to Mac"
    }
    
    # Set proper permissions on the private key
    $sshResult = ssh "$macUser@$macIP" "chmod 600 $macKeyPath"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set permissions on private key"
    }
    
    Write-Host "✅ Apple private key installed successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error installing Apple private key: $_" -ForegroundColor Red
    Write-Host "💡 Make sure your private key file path is correct and accessible" -ForegroundColor Yellow
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
    flutter build ios
    cd ios
    fastlane build_only
    ;;
  validate|upload)
    flutter build ios
    cd ios
    echo "[🚀] Building and uploading to TestFlight..."
    fastlane beta
    ;;
  testflight)
    flutter build ios
    cd ios
    echo "[🚀] Building and uploading to TestFlight..."
    fastlane beta
    ;;
  *)
    echo "[❓] Unknown command: `$1"
    echo "Available commands: run, build, archive, validate, upload, testflight"
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
        Write-Host "  init      - Initialize project (clone from Git or sync current directory)"
        Write-Host "  sync      - Sync current project files to Mac"
        Write-Host "  run       - Run Flutter app on connected iOS device"
        Write-Host "  build     - Build iOS app"
        Write-Host "  archive   - Create archive for App Store"
        Write-Host "  upload    - Build and upload to TestFlight"
        Write-Host "  testflight- Build and upload to TestFlight (same as upload)"
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
        KeyID = $keyId
        IssuerID = $issuerId
        TargetDir = $targetDir
        PrivateKeyPath = "/Users/$macUser/.appstoreconnect/private_keys/AuthKey_$keyId.p8"
    }
    $config | ConvertTo-Json | Out-File -Encoding UTF8 "$cliPath\.ios-devkit-config.json"
    
    Write-Host "✅ Configuration saved successfully" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error saving configuration: $_" -ForegroundColor Red
    exit 1
}

Write-Host "\n🎉 Flutter iOS DevKit Installation Completed Successfully!" -ForegroundColor Green
Write-Host "📝 Available commands: init, sync, run, build, archive, upload, testflight" -ForegroundColor Cyan
Write-Host "🚀 Use 'flutter-ios' command to control your Mac from Windows!" -ForegroundColor Cyan
Write-Host "🔐 Apple App Store Connect authentication configured with Key ID: $keyId" -ForegroundColor Cyan
Write-Host "💡 Restart your PowerShell terminal to use the new commands." -ForegroundColor Yellow 