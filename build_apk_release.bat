@echo off
echo === PulseGpx - Build APK Release ===
cd /d "%~dp0"
call flutter clean
call flutter pub get
call flutter build apk --release --no-shrink --split-debug-info=debug-info

echo.
if exist "build\app\outputs\flutter-apk\app-release.apk" (
    copy "build\app\outputs\flutter-apk\app-release.apk" "PulseGpx-release.apk"
    echo APK : PulseGpx-release.apk
)
pause
