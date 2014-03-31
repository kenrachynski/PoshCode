#Requires -Version 2 -Modules "Metadata"

#.Synopsis
#   Generate the PoshCode Install script 
[CmdletBinding(DefaultParameterSetName="InstallerOnly")]
param(
  # Overrides the PoshCode Module Version
  [Parameter()]
  [Version]$Version,

  # If set, increment the PoshCode version
  [Parameter(ParameterSetName="Package")]
  [Switch]$Increment,

  # Also generate the PoshCode Package
  [Parameter(ParameterSetName="Package", Mandatory=$true)]
  [Switch]$Package,

  # The path to save the package to
  $OutputPath = "${PSScriptRoot}\Releases\"
)

if(!$PSScriptRoot) { $PSScriptRoot = $Pwd }

if(!$Version) {
  $Version = (Import-Metadata "${PSScriptRoot}\PoshCode.psd1").ModuleVersion
}

if($Version -le "0.0") { throw "Can't calculate a version!" }

## TODO: Increment the version number in the psd1 file(s) when asked
if($Increment) {
  if($Version.Revision -ge 0) {
    $Version = New-Object Version $Version.Major, $Version.Minor, $Version.Build, ($Version.Revision + 1)
  } elseif($Version.Build -ge 0) {
    $Version = New-Object Version $Version.Major, $Version.Minor, ($Version.Build + 1)
  } elseif($Version.Minor -ge 0) {
    $Version = New-Object Version $Version.Major, ($Version.Minor + 1)
  }
}

# Note: in the install script we strip the export command, as well as the signature if it's there, and anything delimited by BEGIN FULL / END FULL 
$Constants = (Get-Content $PSScriptRoot\Constants.ps1 -Raw)  -replace "# SIG # Begin signature block(?s:\s.*)" 
$ModuleInfo = (Get-Content $PSScriptRoot\ModuleInfo.psm1 -Raw) -replace '(Export-ModuleMember.*(?m:;|$))','<#$1#>'  -replace "# SIG # Begin signature block(?s:\s.*)" -replace "# FULL # BEGIN FULL(?s:.*?)# FULL # END FULL"
$Configuration = (Get-Content $PSScriptRoot\Configuration.psm1 -Raw) -replace '(Export-ModuleMember.*(?m:;|$))','<#$1#>'  -replace "# SIG # Begin signature block(?s:\s.*)" -replace "# FULL # BEGIN FULL(?s:.*?)# FULL # END FULL"
$InvokeWeb = (Get-Content $PSScriptRoot\InvokeWeb.psm1 -Raw) -replace '(Export-ModuleMember.*(?m:;|$))','<#$1#>'  -replace "# SIG # Begin signature block(?s:\s.*)" -replace "# FULL # BEGIN FULL(?s:.*?)# FULL # END FULL"
$Installation = (Get-Content $PSScriptRoot\Installation.psm1 -Raw) -replace '(Export-ModuleMember.*(?m:;|$))','<#$1#>'  -replace "# SIG # Begin signature block(?s:\s.*)" -replace "# FULL # BEGIN FULL(?s:.*?)# FULL # END FULL"
$InstallScript = Join-Path $OutputPath Install.ps1

Set-Content $InstallScript ((@'
########################################################################
## Copyright (c) 2013 by Joel Bennett, all rights reserved.
## Free for use under MS-PL, MS-RL, GPL 2, or BSD license. Your choice.
########################################################################
#.Synopsis
#   Install a module package to the module repository
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium", DefaultParameterSetName="UserPath")]
param(
  # The package file to be installed
  [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, Position=0)]
  [Alias("PSPath","PackagePath")]
  $Package,

  # The PSModulePath to install to
  [Parameter(ParameterSetName="InstallPath", Mandatory=$true, Position=1)]
  [Alias("PSModulePath")]
  $InstallPath,

  # If set, the module is installed to the Common module path (as specified in PoshCode.ini)
  [Parameter(ParameterSetName="CommonPath", Mandatory=$true)]
  [Switch]$Common,

  # If set, the module is installed to the User module path (as specified in PoshCode.ini)
  [Parameter(ParameterSetName="UserPath")]
  [Switch]$User,

  # If set, overwrite existing modules without prompting
  [Switch]$Force,

  # If set, the module is imported immediately after install
  [Switch]$Import = $true,

  # If set, output information about the files as well as the module 
  [Switch]$Passthru,

  #  Specifies the client certificate that is used for a secure web request. Enter a variable that contains a certificate or a command or expression that gets the certificate.
  #  To find a certificate, use Get-PfxCertificate or use the Get-ChildItem cmdlet in the Certificate (Cert:) drive. If the certificate is not valid or does not have sufficient authority, the command fails.
  [System.Security.Cryptography.X509Certificates.X509Certificate[]]
  $ClientCertificate,

  #  Pass the default credentials
  [switch]$UseDefaultCredentials,

  #  Specifies a user account that has permission to send the request. The default is the current user.
  #  Type a user name, such as "User01" or "Domain01\User01", or enter a PSCredential object, such as one generated by the Get-Credential cmdlet.
  [System.Management.Automation.PSCredential]
  [System.Management.Automation.Credential()]
  [Alias("")]$Credential = [System.Management.Automation.PSCredential]::Empty,

  # Specifies that Authorization: Basic should always be sent. Requires $Credential to be set, and should only be used with https
  [ValidateScript({{if(!($Credential -or $WebSession)){{ throw "ForceBasicAuth requires the Credential parameter be set"}} else {{ $true }}}})]
  [switch]$ForceBasicAuth,

  # Uses a proxy server for the request, rather than connecting directly to the Internet resource. Enter the URI of a network proxy server.
  # Note: if you have a default proxy configured in your internet settings, there is no need to set it here.
  [Uri]$Proxy,

  #  Pass the default credentials to the Proxy
  [switch]$ProxyUseDefaultCredentials,

  #  Pass specific credentials to the Proxy
  [System.Management.Automation.PSCredential]
  [System.Management.Automation.Credential()]
  $ProxyCredential= [System.Management.Automation.PSCredential]::Empty     
)
end {{
  $EAP, $ErrorActionPreference = $ErrorActionPreference, "Stop"

  Write-Progress -Activity "Installing Module" -Status "Validating PoshCode Module" -Id 0
  if($PSBoundParameters.ContainsKey("Package")) {{
    $TargetModulePackage = $PSBoundParameters["Package"]
  }}

  if($PoshCodeModule.GUID -eq '88c6579a-27b2-41c8-86c6-cd23acb791e9' -and $PoshCodeModule.Version -gt '4.0') {{
    $PoshCodeModule = Import-Module PoshCode -Passthru -ErrorAction Stop
    Update-Module PoshCode
  }} else {{
    Write-Progress -Activity "Installing Module" -Status "Installing PoshCode Module" -Id 0

    ## Figure out where to install PoshCode initially 
    if(!$PSBoundParameters.ContainsKey("InstallPath")) {{
      $PSBoundParameters["InstallPath"] = $InstallPath = Select-ModulePath
      Write-Verbose ("Selected Module Path: " + $PSBoundParameters["InstallPath"])
    }}

    $PSBoundParameters["Package"] = "http://PoshCode.org/Modules/PoshCode.packageInfo"
    Install-Module @PSBoundParameters

    # Ditch the temporary module and import the real one
    Remove-Module PoshCodeTemp
    $PoshCodeModule = Import-Module PoshCode -Passthru -ErrorAction Stop
    if($TargetModulePackage) {{
      Write-Warning "PoshCode Module Installed"
    }}

    # Since we just installed the PoshCode module, we will update the config data with the path they picked
    $ConfigData = Get-ConfigData
    if($InstallPath -match ([Regex]::Escape([Environment]::GetFolderPath("Personal")) + "*")) {{
      $ConfigData.InstallPaths["UserPath"] = $InstallPath
    }} elseif($InstallPath -match ([Regex]::Escape([Environment]::GetFolderPath("ProgramFiles")) + "*")) {{
      $ConfigData.InstallPaths["CommonPath"] = $InstallPath
    }} else {{
      $ConfigData.InstallPaths["Default"] = $InstallPath
    }}
    Set-ConfigData -ConfigData $ConfigData

    &$PoshCodeModule {{ Test-ExecutionPolicy }}

  }}

  if($TargetModulePackage) {{
    Write-Progress -Activity "Installing Module" -Status "Installing Package $TargetModulePackage" -Id 0
    $PSBoundParameters["Package"] = $TargetModulePackage
    Install-Module @PSBoundParameters -ErrorAction Stop
    Write-Progress -Activity "Installing Module" -Status "Package Installed Successfully" -Id 0
  }}
  
}}

begin {{
  Set-StrictMode -Off
  $PoshCodeModule = Get-Module PoshCode -ListAvailable

  if(!$PoshCodeModule -or ($PoshCodeModule.GUID -ne '88c6579a-27b2-41c8-86c6-cd23acb791e9') -or $PoshCodeModule.Version -lt '4.0.0') {{

    New-Module -Name PoshCodeTemp {{

###############################################################################
{0}
###############################################################################
{1}
###############################################################################
{2}
###############################################################################
{3}
###############################################################################
{4}
###############################################################################

    }} | Import-Module
  }}
}}
'@
) -f $Constants, $ModuleInfo, $Configuration, $InvokeWeb, $Installation)


Sign $InstallScript -WA 0 -EA 0
if($Package) {
   (Get-Module PoshCode).FileList | Get-Item | Where { ".psm1",".ps1",".ps1xml",".dll" -contains $_.Extension } | Sign

   Write-Host
   if($PSBoundParameters.ContainsKey("Version") -or $PSBoundParameters.ContainsKey("Increment")) {
      Write-Warning "Setting PoshCode version to $Version ..."
      Set-ModuleInfo PoshCode -Version $Version
   }
   $Files = Get-Module PoshCode | Compress-Module -OutputPath $OutputPath
   @(Get-Item $InstallScript) + @($Files) | Out-Default

}
