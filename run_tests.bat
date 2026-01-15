@echo off
if "%~1"=="" (
    echo Usage: run_tests.bat [TestClassName]
    echo Example: run_tests.bat BasicOperationsTest
    exit /b 1
)

echo Compiling...
javac -cp "SQM_HW\junit.jar;SQM_HW\hamcrest.jar;." SQM_HW\*.java
if %errorlevel% neq 0 exit /b %errorlevel%

echo Running Tests: %1
java -cp "SQM_HW\junit.jar;SQM_HW\hamcrest.jar;." org.junit.runner.JUnitCore SQM_HW.%1
pause
