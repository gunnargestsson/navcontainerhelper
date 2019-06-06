<# 
 .Synopsis
  Publish App to a NAV/BC Container
 .Description
  Copies the appFile to the container if necessary
  Creates a session to the container and runs the CmdLet Publish-NavApp in the container
 .Parameter containerName
  Name of the container in which you want to publish an app (default is navserver)
 .Parameter appFile
  Path of the app you want to publish  
 .Parameter skipVerification
  Include this parameter if the app you want to publish is not signed
 .Parameter sync
  Include this parameter if you want to synchronize the app after publishing
  .Parameter syncMode
   Specify Add, Clean or Development based on how you want to synchronize the database schema. Default is Add
 .Parameter install
  Include this parameter if you want to install the app after publishing
 .Parameter tenant
  If you specify the install switch, then you can specify the tenant in which you want to install the app
 .Parameter packageType
  Specify Extension or SymbolsOnly based on which package you want to publish
 .Parameter scope
  Specify Global or Tenant based on how you want to publish the package. Default is Global
 .Parameter useDevEndpoint
  Specify the useDevEndpoint switch if you want to publish using the Dev Endpoint (like VS Code). This allows VS Code to re-publish.
 .Parameter language
  Specify language version that is used for installing the app. The value must be a valid culture name for a language in Business Central, such as en-US or da-DK. If the specified language does not exist on the Business Central Server instance, then en-US is used.
 .Example
  Publish-NavContainerApp -appFile c:\temp\myapp.app
 .Example
  Publish-NavContainerApp -containerName test2 -appFile c:\temp\myapp.app -skipVerification
 .Example
  Publish-NavContainerApp -containerName test2 -appFile c:\temp\myapp.app -install
 .Example
  Publish-NavContainerApp -containerName test2 -appFile c:\temp\myapp.app -skipVerification -install -tenant mytenant
#>
function Publish-NavContainerApp {
    Param(
        [string] $containerName = "navserver",
        [Parameter(Mandatory=$true)]
        [string] $appFile,
        [switch] $skipVerification,
        [switch] $sync,
        [Parameter(Mandatory=$false)]
        [ValidateSet('Add','Clean','Development','ForceSync')]
        [string] $syncMode,
        [switch] $install,
        [Parameter(Mandatory=$false)]
        [string] $tenant = "default",
        [ValidateSet('Extension','SymbolsOnly')]
        [string] $packageType = 'Extension',
        [Parameter(Mandatory=$false)]
        [ValidateSet('Global','Tenant')]
        [string] $scope,
        [switch] $useDevEndpoint,
        [string] $language = ""
    )

    Add-Type -AssemblyName System.Net.Http
    $customconfig = Get-NavContainerServerConfiguration -ContainerName $containerName

    $copied = $false
    if ($appFile.ToLower().StartsWith("http://") -or $appFile.ToLower().StartsWith("https://")) {
        $appUrl = $appFile
        $appFile = Join-Path $extensionsFolder "$containerName\my\$([System.Uri]::UnescapeDataString([System.IO.Path]::GetFileName($appUrl).split("?")[0]))"
        (New-Object System.Net.WebClient).DownloadFile($appUrl, $appFile)
        $copied = $true
    }

    $containerAppFile = Get-NavContainerPath -containerName $containerName -path $appFile
    if ("$containerAppFile" -eq "") {
        $containerAppFile = Join-Path "c:\run\my" ([System.IO.Path]::GetFileName($appFile))
        Copy-FileToNavContainer -containerName $containerName -localPath $appFile -containerPath $containerAppFile
        $copied = $true
    }


    if ($useDevEndpoint) {

        $handler = New-Object  System.Net.Http.HttpClientHandler
        if ($customConfig.ClientServicesCredentialType -eq "Windows") {
            $handler.UseDefaultCredentials = $true
        }
        $HttpClient = [System.Net.Http.HttpClient]::new($handler)
        if ($customConfig.ClientServicesCredentialType -eq "NavUserPassword") {
            $pair = ("$($Credential.UserName):"+[System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)))
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
            $base64 = [System.Convert]::ToBase64String($bytes)
            $HttpClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $base64);
        }
        $HttpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $HttpClient.DefaultRequestHeaders.ExpectContinue = $false
        
        if ($customConfig.DeveloperServicesSSLEnabled -eq "true") {
            $protocol = "https://"
        }
        else {
            $protocol = "http://"
        }
    
        $ip = Get-NavContainerIpAddress -containerName $containerName
        if ($ip) {
            $devServerUrl = "$($protocol)$($ip):$($customConfig.DeveloperServicesPort)/$($customConfig.ServerInstance)"
        }
        else {
            $devServerUrl = "$($protocol)$($containerName):$($customConfig.DeveloperServicesPort)/$($customConfig.ServerInstance)"
        }
    
        $sslVerificationDisabled = ($protocol -eq "https://")
        if ($sslVerificationDisabled) {
            if (-not ([System.Management.Automation.PSTypeName]"SslVerification").Type)
            {
                Add-Type -TypeDefinition "
                    using System.Net.Security;
                    using System.Security.Cryptography.X509Certificates;
                    public static class SslVerification
                    {
                        private static bool ValidationCallback(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; }
                        public static void Disable() { System.Net.ServicePointManager.ServerCertificateValidationCallback = ValidationCallback; }
                        public static void Enable()  { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; }
                    }"
            }
            Write-Host "Disabling SSL Verification"
            [SslVerification]::Disable()
        }
    
        $url = "$devServerUrl/dev/apps?SchemaUpdateMode=synchronize"
        if ($Scope -eq "Tenant") {
            $url += "&tenant=$tenant"
        }
        
        $appName = [System.IO.Path]::GetFileName($appFile)
        
        $multipartContent = [System.Net.Http.MultipartFormDataContent]::new()
        $FileStream = [System.IO.FileStream]::new($appFile, [System.IO.FileMode]::Open)
        try {
            $fileHeader = [System.Net.Http.Headers.ContentDispositionHeaderValue]::new("form-data")
            $fileHeader.Name = "$AppName"
            $fileHeader.FileName = "$appName"
            $fileHeader.FileNameStar = "$appName"
            $fileContent = [System.Net.Http.StreamContent]::new($FileStream)
            $fileContent.Headers.ContentDisposition = $fileHeader
            $multipartContent.Add($fileContent)
            Write-Host "Publishing $appName to $url"
            $result = $HttpClient.PostAsync($url, $multipartContent).GetAwaiter().GetResult()
            if (!$result.IsSuccessStatusCode) {
                throw "Status Code $($result.StatusCode) : $($result.ReasonPhrase)"
            }
            Write-Host -ForegroundColor Green "New Application successfully published to $containerName"
        }
        finally {
            $FileStream.Close()
        }
    
        if ($sslverificationdisabled) {
            Write-Host "Re-enablssing SSL Verification"
            [SslVerification]::Enable()
        }

    }
    else {

        Invoke-ScriptInNavContainer -containerName $containerName -ScriptBlock { Param($appFile, $skipVerification, $sync, $install, $tenant, $syncMode, $packageType, $scope, $language)
    
    
            $publishArgs = @{ "packageType" = $packageType }
            if ($scope) {
                $publishArgs += @{ "Scope" = $scope }
                if ($scope -eq "Tenant") {
                    $publishArgs += @{ "Tenant" = $tenant }
                }
            }
    
            Write-Host "Publishing $appFile"
            Publish-NavApp -ServerInstance $ServerInstance -Path $appFile -SkipVerification:$SkipVerification @publishArgs

            if ($sync -or $install) {
                $appName = (Get-NAVAppInfo -Path $appFile).Name
                $appVersion = (Get-NAVAppInfo -Path $appFile).Version
        
                $syncArgs = @{}
                if ($syncMode) {
                    $syncArgs += @{ "Mode" = $syncMode }
                }
    
                if ($sync) {
                    Write-Host "Synchronizing $appName on tenant $tenant"
                    Sync-NavTenant -ServerInstance $ServerInstance -Tenant $tenant -Force
                    Sync-NavApp -ServerInstance $ServerInstance -Name $appName -Version $appVersion -Tenant $tenant @syncArgs -force -WarningAction Ignore
                }
        
                if ($install) {

                    $languageArgs = @{}
                    if ($language) {
                        $languageArgs += @{ "Language" = $language }
                    }
                    Write-Host "Installing $appName on tenant $tenant"
                    Install-NavApp -ServerInstance $ServerInstance -Name $appName -Version $appVersion -Tenant $tenant @languageArgs
                }
            }
        } -ArgumentList $containerAppFile, $skipVerification, $sync, $install, $tenant, $syncMode, $packageType, $scope, $language
    }

    if ($copied) { 
        Remove-Item $appFile -Force
    }
    Write-Host -ForegroundColor Green "App successfully published"
}
Set-Alias -Name Publish-BCContainerApp -Value Publish-NavContainerApp
Export-ModuleMember -Function Publish-NavContainerApp -Alias Publish-BCContainerApp
