@echo off
echo === PulseGpx - Build APK ===
echo.

REM Aller dans le dossier du projet
cd /d "%~dp0"

REM Nettoyer
echo [1/3] Nettoyage...
call flutter clean

REM Dependances
echo [2/3] Dependances...
call flutter pub get

REM Build APK debug (plus fiable)
echo [3/3] Build APK...
call flutter build apk --debug --no-shrink

echo.
echo === APK genere dans : build\app\outputs\flutter-apk\app-debug.apk ===
echo.

REM Copier l'APK a la racine pour faciliter l'acces
if exist "build\app\outputs\flutter-apk\app-debug.apk" (
    copy "build\app\outputs\flutter-apk\app-debug.apk" "PulseGpx-debug.apk"
    echo APK copie : PulseGpx-debug.apk
) else if exist "build\app\outputs\apk\debug\app-debug.apk" (
    copy "build\app\outputs\apk\debug\app-debug.apk" "PulseGpx-debug.apk"
    echo APK copie : PulseGpx-debug.apk
)

pause
