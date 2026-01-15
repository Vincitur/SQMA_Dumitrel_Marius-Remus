<#
    .Synopsis
    Upgrades the version information in the register from the current Jenkins war file.
    .Description
    The purpose of this script is to update the version of Jenkins in the registry
    when the user may have upgraded the war file in place. The script probes the
    registry for information about the Jenkins install (path to war, etc.) and 
    then grabs the version information from the war to update the values in the
    registry so they match the version of the war file. 

    This will help with security scanners that look in the registry for versions
    of software and flag things when they are too low. The information in the 
    registry may be very old compared to what version of the war file is 
    actually installed on the system.
#>


# Self-elevate the script if required
if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    # We may be running under powershell.exe or pwsh.exe, make sure we relaunch the same one.
    $Executable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
        # Launching with RunAs to get elevation
        $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
        Start-Process -FilePath $Executable -Verb Runas -ArgumentList $CommandLine
        Exit
    }
}

function New-TemporaryDirectory {
    $Parent = [System.IO.Path]::GetTempPath()
    do {
        $Name = [System.IO.Path]::GetRandomFileName()
        $Item = New-Item -Path $Parent -Name $Name -ItemType "Directory" -ErrorAction SilentlyContinue
    } while (-not $Item)
    return $Item.FullName
}

function Exit-Script($Message, $Fatal = $False) {
    $ExitCode = 0
    if($Fatal) {
        Write-Error $Message
    } else {
        Write-Host $Message
    }
    Read-Host "Press ENTER to continue"
    Exit $ExitCode
}

# Let's find the location of the war file...
$JenkinsDir = Get-ItemPropertyValue -Path HKLM:\Software\Jenkins\InstalledProducts\Jenkins -Name InstallLocation -ErrorAction SilentlyContinue

if (($Null -eq $JenkinsDir) -or [String]::IsNullOrWhiteSpace($JenkinsDir)) {
    Exit-Script -Message "Jenkins does not seem to be installed. Please verify you have previously installed using the MSI installer" -Fatal $True
}

$WarPath = Join-Path $JenkinsDir "jenkins.war"
if(-Not (Test-Path $WarPath)) {
    Exit-Script -Message "Could not find war file at location found in registry, please verify Jenkins installation" -Fatal $True
}

# Get the MANIFEST.MF file from the war file to get the version of Jenkins
$TempWorkDir = New-TemporaryDirectory
$ManifestFile = Join-Path $TempWorkDir "MANIFEST.MF"
$Zip = [IO.Compression.ZipFile]::OpenRead($WarPath)
$Zip.Entries | Where-Object { $_.Name -like "MANIFEST.MF" } | ForEach-Object { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, $ManiFestFile, $True) }
$Zip.Dispose()

$JenkinsVersion = $(Get-Content $ManiFestFile | Select-String -Pattern "^Jenkins-Version:\s*(.*)" | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 1)
Remove-Item -Path $ManifestFile

# Convert the Jenkins version into what should be in the registry
$VersionItems = $JenkinsVersion.Split(".") | ForEach-Object { [int]::Parse($_) }

# Use the same encoding algorithm as the installer to encode the version into the correct format 
$RegistryEncodedVersion = 0
$Major = $VersionItems[0]
if ($VersionItems.Length -le 2) {
    $Minor = 0
    if (($VersionItems.Length -gt 1) -and ($VersionItems[1] -gt 255)) {
        $Minor = $VersionItems[1]
        $RegistryEncodedVersion = $RegistryEncodedVersion -bor ((($Major -band 0xff) -shl 24) -bor 0x00ff0000 -bor (($Minor * 10) -band 0x0000ffff))
    }
    else {
        $RegistryEncodedVersion = $RegistryEncodedVersion -bor (($Major -band 0xff) -shl 24)
    }
}
else {
    $Minor = $VersionItems[1]
    if ($Minor -gt 255) {
        $RegistryEncodedVersion = $RegistryEncodedVersion -bor ((($Major -band 0xff) -shl 24) -bor 0x00ff0000 -bor ((($Minor * 10) + $VersionItems[2]) -band 0x0000ffff))
    }
    else {
        $RegistryEncodedVersion = $RegistryEncodedVersion -bor ((($Major -band 0xff) -shl 24) -bor (($Minor -band 0xff) -shl 16) -bor ($VersionItems[2] -band 0x0000ffff))
    }
}

$ProductName = "Jenkins $JenkinsVersion"

# Find the registry key for Jenkins in the Installer\Products area and CurrentVersion\Uninstall
$JenkinsProductsRegistryKey = Get-ChildItem -Path HKLM:\SOFTWARE\Classes\Installer\Products  | Where-Object { $_.GetValue("ProductName", "").StartsWith("Jenkins") }

$JenkinsUninstallRegistryKey = Get-ChildItem -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall  | Where-Object { $_.GetValue("DisplayName", "").StartsWith("Jenkins") }

if (($Null -eq $JenkinsProductsRegistryKey) -or ($Null -eq $JenkinsUninstallRegistryKey)) {
    Exit-Script -Message "Could not find the product information for Jenkins" -Fatal $True
}

# Update the Installer\Products area
$RegistryPath = $JenkinsProductsRegistryKey.Name.Substring($JenkinsProductsRegistryKey.Name.IndexOf("\"))

$OldProductName = $JenkinsProductsRegistryKey.GetValue("ProductName", "")
if ($OldProductName -ne $ProductName) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "ProductName" -Type String -Value $ProductName 
}

$OldVersion = $JenkinsProductsRegistryKey.GetValue("Version", 0)
if ($OldVersion -ne $RegistryEncodedVersion) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "Version" -Type DWord -Value $RegistryEncodedVersion
}

# Update the Uninstall area
$RegistryPath = $JenkinsUninstallRegistryKey.Name.Substring($JenkinsUninstallRegistryKey.Name.IndexOf("\"))
$OldDisplayName = $JenkinsUninstallRegistryKey.GetValue("DisplayName", "")
if ($OldDisplayName -ne $ProductName) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "DisplayName" -Type String -Value $ProductName
}

$OldDisplayVersion = $JenkinsUninstallRegistryKey.GetValue("DisplayVersion", "")
$DisplayVersion = "{0}.{1}.{2}" -f ($RegistryEncodedVersion -shr 24), (($RegistryEncodedVersion -shr 16) -band 0xff), ($RegistryEncodedVersion -band 0xffff)
if ($OldDisplayVersion -ne $DisplayVersion) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "DisplayVersion" -Type String -Value $DisplayVersion
}

$OldVersion = $JenkinsUninstallRegistryKey.GetValue("Version", 0)
if ($OldVersion -ne $RegistryEncodedVersion) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "Version" -Type DWord -Value $RegistryEncodedVersion
}

$OldVersionMajor = $JenkinsUninstallRegistryKey.GetValue("VersionMajor", 0)
$VersionMajor = $RegistryEncodedVersion -shr 24
if ($OldVersionMajor -ne $VersionMajor) {

    Set-ItemProperty -Path HKLM:$RegistryPath -Name "VersionMajor" -Type DWord -Value $VersionMajor
}

$OldVersionMinor = $JenkinsUninstallRegistryKey.GetValue("VersionMinor", 0)
$VersionMinor = ($RegistryEncodedVersion -shr 16) -band 0xff
if ($OldVersionMinor -ne $VersionMinor) {
    Set-ItemProperty -Path HKLM:$RegistryPath -Name "VersionMinor" -Type DWord -Value $VersionMinor
}

Read-Host "Press ENTER to continue"

# SIG # Begin signature block
# MIIqAQYJKoZIhvcNAQcCoIIp8jCCKe4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDbyeWzg9oNvcU/
# j3Q0982rRxp4werHyv0Gv0YLxmkVkaCCDlowggawMIIEmKADAgECAhAIrUCyYNKc
# TJ9ezam9k67ZMA0GCSqGSIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0z
# NjA0MjgyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQDVtC9C0CiteLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0
# JAfhS0/TeEP0F9ce2vnS1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJr
# Q5qZ8sU7H/Lvy0daE6ZMswEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhF
# LqGfLOEYwhrMxe6TSXBCMo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+F
# LEikVoQ11vkunKoAFdE3/hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh
# 3K3kGKDYwSNHR7OhD26jq22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJ
# wZPt4bRc4G/rJvmM1bL5OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQay
# g9Rc9hUZTO1i4F4z8ujo7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbI
# YViY9XwCFjyDKK05huzUtw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchAp
# QfDVxW0mdmgRQRNYmtwmKwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRro
# OBl8ZhzNeDhFMJlP/2NPTLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IB
# WTCCAVUwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+
# YXsIiGX0TkIwHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0P
# AQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAC
# hjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9v
# dEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAED
# MAgGBmeBDAEEATANBgkqhkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql
# +Eg08yy25nRm95RysQDKr2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFF
# UP2cvbaF4HZ+N3HLIvdaqpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1h
# mYFW9snjdufE5BtfQ/g+lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3Ryw
# YFzzDaju4ImhvTnhOE7abrs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5Ubdld
# AhQfQDN8A+KVssIhdXNSy0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw
# 8MzK7/0pNVwfiThV9zeKiwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnP
# LqR0kq3bPKSchh/jwVYbKyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatE
# QOON8BUozu3xGFYHKi8QxAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bn
# KD+sEq6lLyJsQfmCXBVmzGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQji
# WQ1tygVQK+pKHJ6l/aCnHwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbq
# yK+p/pQd52MbOoZWeE4wggeiMIIFiqADAgECAhADJPGbkeizM3ep7tjv4Oh/MA0G
# CSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwHhcNMjMwNDAzMDAwMDAwWhcNMjYwNTE2
# MjM1OTU5WjCBqTELMAkGA1UEBhMCVVMxETAPBgNVBAgTCERlbGF3YXJlMRMwEQYD
# VQQHEwpXaWxtaW5ndG9uMTgwNgYDVQQKEy9DREYgQmluYXJ5IFByb2plY3QgYSBT
# ZXJpZXMgb2YgTEYgUHJvamVjdHMsIExMQzE4MDYGA1UEAxMvQ0RGIEJpbmFyeSBQ
# cm9qZWN0IGEgU2VyaWVzIG9mIExGIFByb2plY3RzLCBMTEMwggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDfqgZcXDJTB5793QlJS7n18mEi24oIQM8oBEYa
# 9swJt4M/pvIyWSSKj0FIKtqOzJQAlaf1cyxOlAisOmsc6K1CCFnnFKvIlyNjRCso
# uoanpbp2Tm0YeoLZhnb71IgWKxcI0Rwida9L+sAsHvsmhWjBQiIs0iAn566nk5UM
# tucGtA4IIK516JmHP8oJxxTgB1X7epupLf0InZeCzd+p36Ct77aCh/wXAnimeBl+
# GrZ+fzHZLCxl7BYk5USiRHVAPJ/nyhqJuOdkHToplFApJBYQYAOhve4S8HWmyqKt
# oBCzeSOQPRYCLQ2bYAo/C23ldMEzEVXd1hju59ZpR4cbJOI4Uhh9tGy0NuzSGhf0
# QdG2XEFdPux/+JW47xpfe4IEkYUq3AKIaZVKWmCZQNoBNrwEmnccYp4tBCsGWO4E
# gcp6V9uChgFpOU4d22hcOxlJjJcTMduqBIskgpoZgoL8RuFXk1P3s9LzROzgJO4F
# d2GljWwDRlut5w/eUuo+++gPmawSKN7FvjvMG3DJGVFBOphwrAGGw7BQ7zSThICJ
# F7kuEFsawCdFNScZSll7FC011U6Hf/6qy/w+lEFhEPFc9GmHO2eQlD/EiU3flXex
# 3qsT0Tagv74AwJHK8Jh6E/WRa2Skqaj3IcPIkm6aZbSPGGNujjXh1KfOGq8hZ/0K
# MUQM2wIDAQABo4ICAzCCAf8wHwYDVR0jBBgwFoAUaDfg67Y7+F8Rhvv+YXsIiGX0
# TkIwHQYDVR0OBBYEFEA4cBGhmjuHUVaxlLPntLnIMLmQMA4GA1UdDwEB/wQEAwIH
# gDATBgNVHSUEDDAKBggrBgEFBQcDAzCBtQYDVR0fBIGtMIGqMFOgUaBPhk1odHRw
# Oi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmlu
# Z1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDBToFGgT4ZNaHR0cDovL2NybDQuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hB
# Mzg0MjAyMUNBMS5jcmwwPgYDVR0gBDcwNTAzBgZngQwBBAEwKTAnBggrBgEFBQcC
# ARYbaHR0cDovL3d3dy5kaWdpY2VydC5jb20vQ1BTMIGUBggrBgEFBQcBAQSBhzCB
# hDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMFwGCCsGAQUF
# BzAChlBodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVk
# RzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNydDAJBgNVHRMEAjAA
# MA0GCSqGSIb3DQEBCwUAA4ICAQA0nYhrG8FM2LQT4e18lk9EgwvuN4ic4A87ci4b
# cxSjYmuUtM2xtsq/9mYROa+7054SbvE2JKyqkvisIb/Ks9zhTSr6hMN0PTO1fKjf
# tth5vBOc7JZTZEsMRJrjZN+zmE6M0w7R67r0TVKbOBWJeUH5g/XMOPaWH8WEEF5S
# m8f2QjmFYyi9inBD5EWBuGK9q4lfda2k2hZ5AY2IddA7apZTiD9QQH3ex/biVVr2
# Zql8TC8918EDnBTwntySMtPLP+GCp416JrQGyapolwbHRDug+hQQJ7+ie8ygWr6K
# 7aAOpvleE/Wjqkl023x6djUdMDe/MbqRDzkOU83osgN9sySIEzTPj5sH+BEjOjNo
# 5jkcPMIvLMeudoweglm+llsnnJMQNLKjik6vp0Klvc3Hphs0Iqo4oEixf5QGA1Ja
# BGsu/nBx94qGJg7zPmCDkTVR/kpbCywrpCnq5CDPMQjR8TkadzG9OUR/nr+YXDX8
# lfzH7MRxoh3dEOh10wduINeGf6FHJhNVcrf4Mts5oLFXLbKTZTPeJ+Vni2BVNOIA
# roQvMFYjIx8YZY0Z2n2xxtePSPh8fPkgH+eeAO/zvZEX0dIz+FudOpsrhO7MTrGl
# XZ5roSeSVy+ZqVngRkJaMCtsf0rd/4uRfxjnsdWWMaiBH4vDa/uI+JjwaPGMRH9C
# +U9y3DGCGv0wghr5AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IENvZGUgU2ln
# bmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENBMQIQAyTxm5HoszN3qe7Y7+DofzAN
# BglghkgBZQMEAgEFAKCB2DAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgSryF4dcs
# 7+G2EseArPHZ/z/KN04sbkO7SZGsfdIrWUgwbAYKKwYBBAGCNwIBDDFeMFygRIBC
# AEoAZQBuAGsAaQBuAHMAIABBAHUAdABvAG0AYQB0AGkAbwBuACAAUwBlAHIAdgBl
# AHIAIAAyAC4ANQAyADgALgAzoRSAEmh0dHBzOi8vamVua2lucy5pbzANBgkqhkiG
# 9w0BAQEFAASCAgBiVVwI5B1HlIEgU0zDQq2ltOZPTs7sX56vCSJcCitWKIJqDBcY
# jdi2Awr6QpvXxqhTEQgkUSB+ppYQeTTVmMk7oHE902S7cMxwUKs9mDAg5rBZGr6B
# swvZJTZYCQceHckDbGXXS4MSxcTtWYKqxF0wR9CQtd7vbI7bcV3oDZzXyfjgsxZW
# LBrGdqqNh8D9+hqb7cs+BdVW6KZxWBNbxyYBt8Gutzy7Cy/ruYsG2hyNVEm2GtOW
# SjBfFW0LHO6QiMzuOf2sa7is+xDR7yeDpb2/nsXKnIj48ULnItus24AoOKs5T7V+
# zoQ6Sm3jnW/+ccFQn5DgYlMFsCjr5ZejGikTsmw56Nm6+3mMLnm+FhyNRX6jprHK
# pq2srxFIw/IpZGHzOS4L2QRo9KkJIM2FxKA+rY0i1gm52MBBhIzt0yv5VgaD4jzH
# TqOXviKPRBcSkeb/bDqW/n3BIKJs6QJVWHVbifWBn/p2Z3O34+/OEFY4Z8muWXKE
# XUEYPPormNLRwQu7KwFiH2j//FaGPL9eGaHXG7krCHFVfc5LTBbhMybcLwzSARpA
# axXjrxKLjoS9Ig5jdo2Mnb6KmIDz9Uk8GHiIqe0g4WNyLyIO1AijCKVyJqa4z100
# 87U56N0Cl13MZiymia6Fcqfu04xV36hi33Xo6cTIjS/Hiij9StdoiK77MqGCF3Yw
# ghdyBgorBgEEAYI3AwMBMYIXYjCCF14GCSqGSIb3DQEHAqCCF08wghdLAgEDMQ8w
# DQYJYIZIAWUDBAIBBQAwdwYLKoZIhvcNAQkQAQSgaARmMGQCAQEGCWCGSAGG/WwH
# ATAxMA0GCWCGSAFlAwQCAQUABCDNSfwf3SFjCHMLhxWjQaMeJwSVoMnhwkEe/Ucp
# AQNG7wIQJe4PT0YRh+2wzVkP9LPiMRgPMjAyNTEyMDkxNjAxMDNaoIITOjCCBu0w
# ggTVoAMCAQICEAqA7xhLjfEFgtHEdqeVdGgwDQYJKoZIhvcNAQELBQAwaTELMAkG
# A1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdp
# Q2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1
# IENBMTAeFw0yNTA2MDQwMDAwMDBaFw0zNjA5MDMyMzU5NTlaMGMxCzAJBgNVBAYT
# AlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQg
# U0hBMjU2IFJTQTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAyMDI1IDEwggIiMA0G
# CSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDQRqwtEsae0OquYFazK1e6b1H/hnAK
# Ad/KN8wZQjBjMqiZ3xTWcfsLwOvRxUwXcGx8AUjni6bz52fGTfr6PHRNv6T7zsf1
# Y/E3IU8kgNkeECqVQ+3bzWYesFtkepErvUSbf+EIYLkrLKd6qJnuzK8Vcn0DvbDM
# emQFoxQ2Dsw4vEjoT1FpS54dNApZfKY61HAldytxNM89PZXUP/5wWWURK+IfxiOg
# 8W9lKMqzdIo7VA1R0V3Zp3DjjANwqAf4lEkTlCDQ0/fKJLKLkzGBTpx6EYevvOi7
# XOc4zyh1uSqgr6UnbksIcFJqLbkIXIPbcNmA98Oskkkrvt6lPAw/p4oDSRZreiwB
# 7x9ykrjS6GS3NR39iTTFS+ENTqW8m6THuOmHHjQNC3zbJ6nJ6SXiLSvw4Smz8U07
# hqF+8CTXaETkVWz0dVVZw7knh1WZXOLHgDvundrAtuvz0D3T+dYaNcwafsVCGZKU
# hQPL1naFKBy1p6llN3QgshRta6Eq4B40h5avMcpi54wm0i2ePZD5pPIssoszQyF4
# //3DoK2O65Uck5Wggn8O2klETsJ7u8xEehGifgJYi+6I03UuT1j7FnrqVrOzaQoV
# JOeeStPeldYRNMmSF3voIgMFtNGh86w3ISHNm0IaadCKCkUe2LnwJKa8TIlwCUNV
# wppwn4D3/Pt5pwIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQU
# 5Dv88jHt/f3X85FxYxlQQ89hjOgwHwYDVR0jBBgwFoAU729TSunkBnx6yuKQVvYv
# 1Ensy04wDgYDVR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMIGV
# BggrBgEFBQcBAQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNl
# cnQuY29tMF0GCCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNB
# MS5jcnQwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVD
# QTEuY3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG
# 9w0BAQsFAAOCAgEAZSqt8RwnBLmuYEHs0QhEnmNAciH45PYiT9s1i6UKtW+FERp8
# FgXRGQ/YAavXzWjZhY+hIfP2JkQ38U+wtJPBVBajYfrbIYG+Dui4I4PCvHpQuPqF
# gqp1PzC/ZRX4pvP/ciZmUnthfAEP1HShTrY+2DE5qjzvZs7JIIgt0GCFD9ktx0Lx
# xtRQ7vllKluHWiKk6FxRPyUPxAAYH2Vy1lNM4kzekd8oEARzFAWgeW3az2xejEWL
# NN4eKGxDJ8WDl/FQUSntbjZ80FU3i54tpx5F/0Kr15zW/mJAxZMVBrTE2oi0fcI8
# VMbtoRAmaaslNXdCG1+lqvP4FbrQ6IwSBXkZagHLhFU9HCrG/syTRLLhAezu/3Lr
# 00GrJzPQFnCEH1Y58678IgmfORBPC1JKkYaEt2OdDh4GmO0/5cHelAK2/gTlQJIN
# qDr6JfwyYHXSd+V08X1JUPvB4ILfJdmL+66Gp3CSBXG6IwXMZUXBhtCyIaehr0Xk
# BoDIGMUG1dUtwq1qmcwbdUfcSYCn+OwncVUXf53VJUNOaMWMts0VlRYxe5nK+At+
# DI96HAlXHAL5SlfYxJ7La54i71McVWRP66bW+yERNpbJCjyCYG2j+bdpxo/1Cy4u
# PcU3AWVPGrbn5PhDBf3Froguzzhk++ami+r3Qrx5bIbY3TVzgiFI7Gq3zWcwgga0
# MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIxCzAJ
# BgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5k
# aWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAe
# Fw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcw
# FQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3Rl
# ZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIiMA0G
# CSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0ZodLRR
# F51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi6wui
# m5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNgxVBd
# Jkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiFcMSk
# qTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJm/s8
# 0FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvSGmhg
# aTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1ZlAe
# SpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9MmeO
# reGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7Yk/e
# hb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bGRinZ
# bI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6X5uA
# iynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNV
# HQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJxXWRM
# 3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMI
# MHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNl
# cnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRw
# Oi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAg
# BgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQAD
# ggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxjaaFd
# leMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0hvrV
# 6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0F8HA
# BBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnTmpfe
# Qh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKfZxAv
# BAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzEwlvz
# ZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbhOhZ3
# ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOXgpIU
# sWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EOLLHf
# MR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wGWqbI
# iOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIFjTCCBHWgAwIB
# AgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYDVQQGEwJV
# UzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQu
# Y29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0EwHhcNMjIw
# ODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UE
# ChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYD
# VQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZwuEppz1Y
# q3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lX
# FllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAdYyktzuxe
# TsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3T6cw2Vbu
# yntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I
# 9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNdaSaTC5qmg
# Z92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtmmnTK3kse
# 5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyVw4/3IbKy
# Ebe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwh
# HbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYiCd98THU/
# Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmpsh3lGwID
# AQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7NfjgtJxXWRM
# 3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDgYD
# VR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDov
# L29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUGA1UdHwQ+
# MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3Vy
# ZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRVHSAAMA0GCSqGSIb3DQEBDAUA
# A4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzshV6pGrsi+IcaaVQi7aSI
# d229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096wwepqLsl7U
# z9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcDx4eo0kxA
# GTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsgjTVgHAID
# yyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37YOtnwtoeW
# /VvRXKwYw02fc7cBqZ9Xql4o4rmUMYIDfDCCA3gCAQEwfTBpMQswCQYDVQQGEwJV
# UzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRy
# dXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExAhAK
# gO8YS43xBYLRxHanlXRoMA0GCWCGSAFlAwQCAQUAoIHRMBoGCSqGSIb3DQEJAzEN
# BgsqhkiG9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjUxMjA5MTYwMTAzWjArBgsq
# hkiG9w0BCRACDDEcMBowGDAWBBTdYjCshgotMGvaOLFoeVIwB/tBfjAvBgkqhkiG
# 9w0BCQQxIgQg/6EINEC6D6EsZl5jv8+VoVzuEJ8jggZLs328hs1sECwwNwYLKoZI
# hvcNAQkQAi8xKDAmMCQwIgQgSqA/oizXXITFXJOPgo5na5yuyrM/420mmqM08UYR
# CjMwDQYJKoZIhvcNAQEBBQAEggIAx0olEjMsplBcJu7rVdE/I4vCGtDssx6//1tN
# KcUsX8h227pzcCZ4Dzoylb39hL9rEMp3skQsSRHat6MQIGvjIOMzvKhJy3yvp8ek
# iHUppaBeIX14rZJ9RCgukdz6+aqpFjRVPhjFl0qYse7X7zeP6Jn/0l/SSQIm8PTV
# wJYtF3zQbOsYBcttb7PkzvSJE9LzddhIhsNR2LmNAVRVZlKNQOD58Fr1ozMQqnFT
# tvi2+RiYdXA2eVaXjA/zEQ7pQQSTCSa69ZVUPRInZnmSj8GqnaOU/aQWedpLCc+4
# pW8ZVcscpW0yAsSXg4hKlpnXsNkegbIwbGlzG6E9/HQktPIltRxx8Kg9mIu3A90/
# Z6whbcndvMlYcimpeKZtCv7gseT0sQ76L+d+8ilJkSZxk74hiXohibwaX7gU6ZLn
# CBVj8RihiXivuyAe7lgh0N5mf/2JoVeuhwg+qy/DkCS37UjfyDrJXGQ21Zx4DcfK
# vf+lyBVX37DxfM2pPjCQu0e1mh+GQdgYUQ/T5lWckKzwx9J5qzpCkwokp1NYWzzs
# c6TrNaSpwcoDRkx4tnuvT6MpgzyGtQKnFDoSCynLMbHhr54usDgQAz9UZvgVn4ka
# bNVG+IdQW0wCkkxtHZPVdmWhY1+kZYe68xYu/0xVL8S8KXXi47THdYFwdu8ts+U9
# Xpq5bjU=
# SIG # End signature block
