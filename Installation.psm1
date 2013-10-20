# We're not using Requires because it just gets in the way on PSv2
#!Requires -Version 2 -Modules "Configuration"
#!Requires -Version 2 -Modules "ModuleInfo"
###############################################################################
## Copyright (c) 2013 by Joel Bennett, all rights reserved.
## Free for use under MS-PL, MS-RL, GPL 2, or BSD license. Your choice. 
###############################################################################
## Installation.psm1 defines the core commands for installing packages:
## Install-Module and Expand-ZipFile and Expand-Package
## It depends on the Configuration module and the Invoke-WebRequest cmdlet
## It depends on the ModuleInfo module

# FULL # BEGIN FULL: Don't include this in the installer script
. $PSScriptRoot\Constants.ps1

if(!(Get-Command Invoke-WebReques[t] -ErrorAction SilentlyContinue)){
  Import-Module $PSScriptRoot\InvokeWeb
}
# if(!(Get-Command Import-Metadat[a] -ErrorAction SilentlyContinue)){
#   Import-Module $PSScriptRoot\ModuleInfo
# }

function Update-Module {
   <#
      .Synopsis
         Checks if you have the latest version of each module
      .Description
         Test the ModuleInfoUri indicate if there's an upgrade available
   #>
   [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium")]
   param(
      # The name of the module to package
      [Parameter(ValueFromPipeline=$true)]
      [ValidateNotNullOrEmpty()] 
      $Module = "*",
   
      # Only test to see if there are updates available (don't do the actual updates)
      # This is similar to -WhatIf, except it outputs objects you can examine...
      [Alias("TestOnly")]
      [Switch]$ListAvailable,
   
      # Force an attempt to update even modules which don't have a ModuleInfoUri
      [Switch]$Force,
   
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
      [ValidateScript({if(!($Credential -or $WebSession)){ throw "ForceBasicAuth requires the Credential parameter be set"} else { $true }})]
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
   process {
      $ModuleInfo = Get-Module $Module -ListAvailable | Add-Member NoteProperty Update -Value "Unknown" -Passthru -Force
   
      if(!$Force) {
         # Unless they -Force, filter out modules without package manifests
         $ModuleInfo = $ModuleInfo | Where-Object {$_.ModuleInfoUri}
      }
   
      Write-Verbose "Testing for new versions of $(@($ModuleInfo).Count) modules."
      foreach($M in $ModuleInfo){
         Write-Progress "Updating module $($M.Name)" "Checking for new version (current: $($M.Version))" -id 0
         if(!$M.ModuleInfoUri) {
            # TODO: once the search domain is up, we need to do a search here.
            Write-Warning "Unable to check for update to $($M.Name) because there is no ModuleInfoUri"
            continue
         }
   
         ## Download the ModuleInfoUri and see what version we got...
         $WebParam = @{Uri = $M.ModuleInfoUri}
         # TODO: This is currently very simplistic, based on the URL alone which
         #       requires the URL to have NO query string, and end in a file name
         #       it would be better to have Invoke-Web figure out the file name...
         $WebParam.OutFile = Join-Path ([IO.path]::GetTempPath()) (Split-Path $M.ModuleInfoUri -Leaf)
         try { # A 404 is a terminating error, but I still want to handle it my way.
            $VPR, $VerbosePreference = $VerbosePreference, "SilentlyContinue"
            $WebResponse = Invoke-WebRequest @WebParam -ErrorVariable WebException -ErrorAction SilentlyContinue
         } catch [System.Net.WebException] {
            if(!$WebException) { $WebException = @($_.Exception) }
         } finally {
            $VPR, $VerbosePreference = $VerbosePreference, $VPR
         }
         if($WebException){
            $Source = $WebException[0].InnerException.Response.StatusCode
            if(!$Source) { $Source = $WebException[0].InnerException }

            Write-Warning "Can't fetch ModuleInfo from $($M.ModuleInfoUri) for $($M.Name): $(@($WebException)[0].Message)"
            continue # Check the rest of the modules...
         }
   
         # If we used the built-in Invoke-WebRequest, we don't have the file yet...
         if($ModuleInfoFile -isnot [System.IO.FileInfo]) { $ModuleInfoFile = Get-ChildItem $WebParam.OutFile }
      
         # Now lets find out what the latest version is:
         $ModuleInfoFile = Resolve-Path $ModuleInfoFile -ErrorAction Stop
         $Mi = Import-Metadata $ModuleInfoFile
   
         $M.Update = [Version]$Mi.ModuleVersion
         Write-Verbose "Latest version of $($M.Name) is $($mi.ModuleVersion)"
   
         # They're going to want to install it where it already is:
         # But we want to use the PSModulePath roots, not the path to the actual folder:
         $Paths = $Env:PSModulePath -split ";" | %{ $_.Trim("/\ ") } | sort-object length -desc
         foreach($Path in $Paths) {
           if($M.ModuleManifestPath.StartsWith($Path)) {
             $InstallPath = $Path
             break
           }
         }
   
         # If we need to update ...
         if(!$TestOnly -and $M.Update -gt $M.Version) {
   
            if($PSCmdlet.ShouldProcess("Upgrading the module '$($M.Name)' from version $($M.Version) to $($M.Update)", "Update '$($M.Name)' from version $($M.Version) to $($M.Update)?", "Updating $($M.Name)" )) {
               if(!$InstallPath) {
                  $InstallPath = Split-Path (Split-Path $M.ModuleManifestPath)
               }
      
               $InstallParam = @{InstallPath = $InstallPath} + $PsBoundParameters
               $null = "Module", "TestOnly" | % { $InstallParam.Remove($_) }
      
               # If the InfoUri and the PackageUri are the same, then we already downloaded it
               if($M.ModuleInfoUri -eq $Mi.PackageUri) {
                  $InstallParam.Add("Package", $ModuleInfoFile)
               } else {
                  # Get rid of the temporarily downloaded package info
                  Remove-Item $ModuleInfoFile
                  $InstallParam.Add("Package", $Mi.PackageUri)
               }

               Write-Verbose "Install Module Upgrade:`n$( $InstallParam | Out-String )"
      
               Install-Module @InstallParam
            }
         } elseif($TestOnly) {
            $M | Select-Object Name, Author, Version, Update, PackageUri, ModuleInfoUri, ModuleInfoPath, @{name="PSModulePath"; expression={$InstallPath}}
         }
      }
   }
}

# Internal function called by Expand-Package when the package isn't a PoshCode package.
# NOTE: ZIP File Support not included in Install.ps1
# TODO: Validate Output is a valid module: Specifically check folder name = module manifest name
function Expand-ZipFile {
   #.Synopsis
   #   Expand a zip file, ensuring it's contents go to a single folder ...
   [CmdletBinding(SupportsShouldProcess=$true)]
   param(
     # The path of the zip file that needs to be extracted
     [Parameter(Position=0, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
     [Alias("PSPath")]
     $FilePath,
   
     # The base path where we want the output folder to end up
     [Parameter(Position=1, Mandatory=$true)] 
     $OutputPath,
   
     # Make sure the resulting folder is always named the same as the archive
     [Switch]$Force
   )
   process {
      $ZipFile = Get-Item $FilePath -ErrorAction Stop
      $OutputFolderName = $ZipFile.BaseName
      
      # Figure out where we'd prefer to end up:
      if(Test-Path $OutputPath -Type Container) {
         # If they pass a path that exists, resolve it:
         $OutputPath = Convert-Path $OutputPath
         
         # If it's not empty, assume they want us to make a folder there:
         # Unless it already exists:
         if((Get-ChildItem $OutputPath) -and ($OutputFolderName -ne (Split-Path $OutputPath -Leaf))) {
            $Destination = (New-Item (Join-Path $OutputPath $OutputFolderName) -Type Directory -Force).FullName
            # Otherwise, we could just use that folder (maybe):
         } else {
            $Destination = $OutputPath
         }
      } else {
         # Otherwise, assume they want us to make a new folder:
         $Destination = (New-Item $OutputPath -Type Directory -Force).FullName
      }

      # If the Destination Directory is empty, or they want to overwrite
      if($Force -Or !(Get-ChildItem $Destination) -or  $PSCmdlet.ShouldContinue("The output location '$Destination' already exists, and is not empty: do you want to replace it?", "Installing $FilePath", [ref]$ConfirmAllOverwriteOnInstall, [ref]$RejectAllOverwriteOnInstall)) {
         $success = $false
         if(Test-Path $Destination) {
            Remove-Item $Destination -Recurse -Force -ErrorAction Stop
         }
         $Destination = (New-Item $Destination -Type Directory -Force).FullName
      } else {
         $PSCmdlet.ThrowTerminatingError( (New-Object System.Management.Automation.ErrorRecord (New-Object System.Management.Automation.HaltCommandException "Can't overwrite $Destination folder: User Refused"), "ShouldContinue:False", "OperationStopped", $_) )
      }
      
      if("System.IO.Compression.ZipFile" -as [Type]) {
         # If we have .Net 4, this is better (no GUI)
         try {
            $Archive = [System.IO.Compression.ZipFile]::Open( $ZipFile.FullName, "Read" )
            [System.IO.Compression.ZipFileExtensions]::ExtractToDirectory( $Archive, $Destination )
         } catch { Write-Error $_.Message } finally {
            $Archive.Dispose()
         }
      } else {
         # Note: the major problem with this method is that it has GUI!
         $shellApplication = new-object -com Shell.Application
         $zipPackage = $shellApplication.NameSpace($ZipFile.FullName)
         $shellApplication.NameSpace($Destination).CopyHere($zipPackage.Items())
      }
      
      # Now, a few corrective options:
      # If there are no items, bail.
      $RootItems = @(Get-ChildItem $Destination)
      $RootItemCount = $RootItems.Count
      if($RootItemCount -lt 1) {
         throw "There were no items in the Archive: $($ZipFile.FullName)"
      }
      
      # If there's nothing there but another folder, move it up one.
      while($RootItemCount -eq 1 -and $RootItems[0].PSIsContainer) {
         Write-Verbose "Extracted One Folder ($RootItems) - Moving"
         if($Force -or ($RootItems[0].Name -eq (Split-Path $Destination -Leaf))) { 
            # Keep the archive named folder
            Move-Item (join-path $RootItems[0].FullName *) $destination
            # Remove the child folder
            Remove-Item $RootItems[0].FullName
         } else {
         
            $NewDestination = (Join-Path (Split-Path $Destination) $RootItems[0].Name)
            if(Test-Path $NewDestination) {
               if(Get-ChildItem $NewDestination) {
                  if($Force -or $PSCmdlet.ShouldContinue("The OutputPath exists and is not empty. Do you want to replace the contents of '$NewDestination'?", "Deleting contents of '$NewDestination'")) {
                     Remove-Item $NewDestination -Recurse -ErrorAction Stop
                  } else {
                     throw "OutputPath '$NewDestination' Exists and is not empty."
                  }
               }
               # move the contents to the new location
               Move-Item (join-path $RootItems[0].FullName *) $NewDestination
               Remove-Item $RootItems[0].FullName
            } else {
               # move the whole folder to the new location
               Move-Item $RootItems[0].FullName (Split-Path $NewDestination -Leaf)
            }
            Remove-Item $Destination
            $Destination = $NewDestination
         }
      
         $RootItems = @(Get-ChildItem $Destination)
         $RootItemCount = $RootItems.Count
         if($RootItemCount -lt 1) {
            throw "There were no items in the Archive: $($ZipFile.FullName)"
         }
      }
      # Output the new folder
      Get-Item $Destination
   }
}
# FULL # END FULL

function Install-Module {
   #.Synopsis
   #   Install a module package to the module 
   [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium", DefaultParameterSetName="UserPath")]
   param(
      # The package file to be installed
      [Parameter(ValueFromPipelineByPropertyName=$true, Mandatory=$true, Position=0)]
      [Alias("PSPath","PackagePath","ModuleInfoUri")]
      $Package,
   
      # A custom path to install the module to
      [Parameter(ParameterSetName="InstallPath", Mandatory=$true, Position=1)]
      [Alias("PSModulePath")]
      $InstallPath,
   
      # If set, the module is installed to the Common module path (as specified in Packaging.ini)
      [Parameter(ParameterSetName="CommonPath", Mandatory=$true)]
      [Switch]$Common,
   
      # If set, the module is installed to the User module path (as specified in Packaging.ini). This is the default.
      [Parameter(ParameterSetName="UserPath")]
      [Switch]$User,
   
      # If set, overwrite existing modules without prompting
      [Switch]$Force,
   
      # If set, the module is imported immediately after install
      [Switch]$Import,
   
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
      [ValidateScript({if(!($Credential -or $WebSession)){ throw "ForceBasicAuth requires the Credential parameter be set"} else { $true }})]
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
   dynamicparam {
      $paramDictionary = new-object System.Management.Automation.RuntimeDefinedParameterDictionary
      if(Get-Command Get-ConfigData -ListImported -ErrorAction SilentlyContinue) {
         foreach( $name in (Get-ConfigData).InstallPaths.Keys ){
            if("CommonPath","UserPath" -notcontains $name) {
               $param = new-object System.Management.Automation.RuntimeDefinedParameter( $Name, [Switch], (New-Object Parameter -Property @{ParameterSetName=$Name;Mandatory=$true}))
               $paramDictionary.Add($Name, $param)
            }
         } 
      }
      return $paramDictionary
   }  
   begin {
      if($PSCmdlet.ParameterSetName -ne "InstallPath") {
         $Config = Get-ConfigData
         switch($PSCmdlet.ParameterSetName){
            "UserPath"   { $InstallPath = $Config.InstallPaths.UserPath }
            "CommonPath" { $InstallPath = $Config.InstallPaths.CommonPath }
            # "SystemPath" { $InstallPath = $Config.InstallPaths.SystemPath }
         }
         $null = $PsBoundParameters.Remove(($PSCmdlet.ParameterSetName + "Path"))
         $null = $PsBoundParameters.Add("InstallPath", $InstallPath)
      }
   }
   process {
      # There are a few possibilities here: they might be installing from a web module, in which case we need to download first
      # If we need to download, that's a seperate pre-install step:
      if("$Package" -match "^https?://" ) {
         # Make sure the InstallPath has a file name:
         # TODO: This is currently very simplistic, based on the URL alone which
         #       requires the URL to have NO query string, and end in a file name
         #       it would be better to have Invoke-Web figure out the file name...
         if(Test-Path $InstallPath -PathType Container) {
            $OutFile = Join-Path $InstallPath (Split-Path $Package -Leaf)
         } else {
            $OutFile = $InstallPath
         }
         
         Write-Verbose "Fetch '$Package' to '$OutFile'"
   
         $WebParam = @{} + $PsBoundParameters
         $WebParam.Add("Uri",$Package)
         $WebParam.Add("OutFile",$OutFile)
         $null = "Package", "InstallPath", "Common", "User", "Force", "Import", "Passthru" | % { $WebParam.Remove($_) }
   

         try { # A 404 is a terminating error, but I still want to handle it my way.
            $VPR, $VerbosePreference = $VerbosePreference, "SilentlyContinue"
            $Package = Invoke-WebRequest @WebParam -ErrorVariable WebException -ErrorAction SilentlyContinue
         } catch [System.Net.WebException] {
            if(!$WebException) { $WebException = @($_.Exception) }
         } finally {
            $VPR, $VerbosePreference = $VerbosePreference, $VPR
         }
         if($WebException){
            $Source = $WebException[0].InnerException.Response.StatusCode
            if(!$Source) { $Source = $WebException[0].InnerException }

            $PSCmdlet.ThrowTerminatingError( (New-Object System.Management.Automation.ErrorRecord $WebException[0], "Can't Download $($WebParam.Uri)", "InvalidData", $Source) )
         }

         # If we used the built-in Invoke-WebRequest, we don't have the file yet...
         if($Package -isnot [System.IO.FileInfo]) { $Package = Get-ChildItem $OutFile }
      }

      # At this point, the Package must be a file 
      # TODO: consider supporting install from a (UNC Path) folder for corporate environments
      $PackagePath = Resolve-Path $Package -ErrorAction Stop

      ## If we just got back a module manifest (text file vs. zip/psmx)
      ## Figure out the real package Uri and recurse so we can download it
      # TODO: Check the file contents instead (it's just testing extensions right now)
      if($ModuleInfoExtension -eq [IO.Path]::GetExtension($PackagePath)) {
         Write-Verbose "Downloaded file '$PackagePath' is just a manifest, get PackageUri."
         $MI = Import-Metadata $PackagePath -ErrorAction "SilentlyContinue"
         Remove-Item $PackagePath

         if($Mi.PackageUri) {
            Write-Verbose "Found PackageUri '$($Mi.PackageUri)' in Module Info file '$PackagePath' -- Installing by Uri"
            $PsBoundParameters["Package"] = $Mi.PackageUri
            Install-Module @PsBoundParameters
            return
         } else {
            # TODO: Change this Error Category
            $PSCmdlet.ThrowTerminatingError( (New-Object System.Management.Automation.ErrorRecord (New-Object System.IO.FileFormatException "$PackagePath is not a valid package or package manifest."), "Invalid Package", "InvalidResult", $Package) )
         }
      }

      $InstallPath = "$InstallPath".TrimEnd("\")
   
      # Warn them if they're installing in an irregular location
      [string[]]$ModulePaths = $Env:PSModulePath -split ";" | Resolve-Path -ErrorAction SilentlyContinue | Convert-Path -ErrorAction SilentlyContinue
      if(!($ModulePaths -match ([Regex]::Escape($InstallPath) + ".*"))) {
         if((Get-PSCallStack | Where-Object{ $_.Command -eq "Install-Module" }).Count -le 1) {
            Write-Warning "Install path '$InstallPath' is not in your PSModulePath!"
            $InstallPath = Select-ModulePath $InstallPath
         }
      }

      # At this point $PackagePath is a local file, but it might be a .psmx, or .zip or .nupkg instead
      Write-Verbose "PackagePath: $PackagePath"
      $Manifest = Get-Module $PackagePath
      # Expand the package (psmx/zip: npkg not supported yet)
      $ModuleFolder = Expand-Package $PackagePath $InstallPath -Force:$Force -Passthru:$Passthru -ErrorAction Stop
      if(!(Test-Path (Join-Path $ModuleFolder.FullName $ModuleInfoFile))) {
         Write-Warning "The archive was unpacked to $($ModuleFolder.Fullname), but may not be a valid module (it is missing the package.psd1 manifest)"
      }

      if(!$Manifest) {
         $Manifest = Get-Module $ModuleFolder.Name -ListAvailable | Where-Object { $_.ModuleBase -eq $ModuleFolder.FullName }
      }

      # Now verify the RequiredModules are available, and try installing them.
      if($Manifest -and $Manifest.RequiredModules) {
         $FailedModules = @()
         foreach($RequiredModule in $Manifest.RequiredModules ) {
            # If the module is available ... 
            $VPR = "SilentlyContinue"
            $VPR, $VerbosePreference = $VerbosePreference, $VPR

            if($Module = Get-Module -Name $RequiredModule.ModuleName -ListAvailable) {
               $VPR, $VerbosePreference = $VerbosePreference, $VPR
               if($Module = $Module | Where-Object { $_.Version -ge $RequiredModule.ModuleVersion }) {
                  if($Import) {
                     Import-Module -Name $RequiredModule.ModuleName -MinimumVersion
                  }
                  continue
               } else {
                  Write-Warning "The package $PackagePath requires $($RequiredModule.ModuleVersion) of the $($RequiredModule.ModuleName) module. Yours is version $($Module.Version). Trying upgrade:"
               }
            } else {
               Write-Warning "The package $PackagePath requires the $($RequiredModule.ModuleName) module. Trying install:"
            }

            # Check for a local copy, maybe we get lucky:
            $Folder = Split-Path $PackagePath
            # Check with and without the version number in the file name:
            if(($RequiredFile = Get-Item (Join-Path $Folder "$($RequiredModule.ModuleName)*$ModulePackageExtension") | 
                                  Sort-Object { [IO.Path]::GetFileNameWithoutExtension($_) } | 
                                  Select-Object -First 1) -and
               (Get-Module $RequiredFile).Version -ge $RequiredModule.ModuleVersion)
            {
               Write-Warning "Installing required module $($RequiredModule.ModuleName) from $RequiredFile"
               Install-Module $RequiredFile $InstallPath
               continue
            }

            # If they have a ModuleInfoUri, we can try that:
            if($RequiredModule.ModuleInfoUri) {
               Write-Warning "Installing required module $($RequiredModule.MOduleName) from $($RequiredModule.ModuleInfoUri)"
               Install-Module $RequiredModule.ModuleInfoUri $InstallPath
               continue
            } 
   
            Write-Warning "The module package does not have a ModuleInfoUri for the required module $($RequiredModule.MOduleName), and there's not a local copy."
            $FailedModules += $RequiredModule
            continue
         }
         if($FailedModules) {
            Write-Error "Unable to resolve required modules."
            Write-Output $FailedModules
            return # TODO: Should we install anyway? Prompt?
         }
      }

      if($Import -and $ModuleFolder) {
         Write-Verbose "Import-Module Requested. Importing $($ModuleFolder.Name)"
         Import-Module $ModuleFolder.Name -Passthru:$Passthru
      } elseif($ModuleFolder) {
         Write-Verbose "No Import. Get-Module: $($ModuleFolder.Name) -ListAvailable"
         Get-Module $ModuleFolder.Name -ListAvailable | Where-Object { $_.ModuleBase -eq $ModuleFolder.FullName }
      }
      Write-Verbose "Done. Done!"
   }
}

# Internal function called by Install-Module to unpack the Module Package
# TODO: Test (and fix) behavior with Nuget packages
#       * Ideally: make sure we only end up with a single folder with the same name as the main assembly
#       * Ideally: if it's a nuget development package, generate a module manifest
#       * Ideally: find and test some of the nupkg files made by PSGet lovers -- make sure we do the right thing for them 
function Expand-Package {
   #.Synopsis
   #   Expand a zip file, ensuring it's contents go to a single folder ...
   [CmdletBinding(SupportsShouldProcess=$true)]
   param(
      # The path of the module package that needs to be extracted
      [Parameter(Position=0, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
      [Alias("PSPath")]
      $PackagePath,

      # The base path where we want the module folder to end up
      [Parameter(Position=1)] 
      $InstallPath = $(Split-Path $PackagePath),

      # If set, overwrite existing modules without prompting
      [Switch]$Force,

      # If set, output information about the files as well as the module 
      [Switch]$Passthru    
   )
   begin {
      if(!(Test-Path variable:RejectAllOverwriteOnInstall)){
         $RejectAllOverwriteOnInstall = $false;
         $ConfirmAllOverwriteOnInstall = $false;
      }
   }
   process {
      try {
         $PackagePath = Convert-Path $PackagePath
         $Package = [System.IO.Packaging.Package]::Open( $PackagePath, "Open", "Read" )
         $ModuleVersion = if($Package.PackageProperties.Version) {$Package.PackageProperties.Version } else {""}
         Write-Verbose ($Package.PackageProperties|Select-Object Title,Version,@{n="Guid";e={$_.Identifier}},Creator,Description, @{n="Package";e={$PackagePath}}|Out-String)

         if($ModuleResult = $ModuleName = $Package.PackageProperties.Title) {
            if($InstallPath -match ([Regex]::Escape($ModuleName)+'$')) {
               $InstallPath = Split-Path $InstallPath
            }
         } else {
            $Name = Split-Path $PackagePath -Leaf
            $Name = @($Name -split "[\-\.]")[0]
            if($InstallPath -match ([Regex]::Escape((Join-Path (Split-Path $PackagePath) $Name)))) {
               $InstallPath = Split-Path $InstallPath
            }
         }

         if(!@($Package.GetParts())) {
            $Package.Close()
            $Package.Dispose()
            $Package = $null

            $Output = Expand-ZipFile -FilePath $PackagePath -OutputPath $InstallPath -Force:$Force
            if($Passthru) {
               Get-ChildItem $Output -Recurse
            }
            return
         }

         if($PSCmdlet.ShouldProcess("Extracting the module '$ModuleName' to '$InstallPath\$ModuleName'", "Extract '$ModuleName' to '$InstallPath\$ModuleName'?", "Installing $ModuleName $ModuleVersion" )) {
            if($Force -Or !(Test-Path "$InstallPath\$ModuleName" -ErrorAction SilentlyContinue) -Or $PSCmdlet.ShouldContinue("The module '$InstallPath\$ModuleName' already exists, do you want to replace it?", "Installing $ModuleName $ModuleVersion", [ref]$ConfirmAllOverwriteOnInstall, [ref]$RejectAllOverwriteOnInstall)) {
               $success = $false
               if(Test-Path "$InstallPath\$ModuleName") {
                  Remove-Item "$InstallPath\$ModuleName" -Recurse -Force -ErrorAction Stop
               }
               $ModuleResult = New-Item -Type Directory -Path "$InstallPath\$ModuleName" -Force -ErrorVariable FailMkDir
             
               ## Handle the error if they asked for -Common and don't have permissions
               if($FailMkDir -and @($FailMkDir)[0].CategoryInfo.Category -eq "PermissionDenied") {
                  throw "You do not have permission to install a module to '$InstallPath\$ModuleName'. You may need to be elevated."
               }

               foreach($part in $Package.GetParts() | where Uri -match ("^/" + $ModuleName)) {
                  $fileSuccess = $false
                  # Copy the data to the file system
                  try {
                     if(!(Test-Path ($Folder = Split-Path ($File = Join-Path $InstallPath $Part.Uri)) -EA 0) ){
                        $null = New-Item -Type Directory -Path $Folder -Force
                     }
                     Write-Verbose "Unpacking $File"
                     $writer = [IO.File]::Open( $File, "Create", "Write" )
                     $reader = $part.GetStream()

                     Copy-Stream $reader $writer -Activity "Writing $file"
                     $fileSuccess = $true
                  } catch [Exception] {
                     $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord $_.Exception, "Unexpected Exception", "InvalidResult", $_) )
                  } finally {
                     if($writer) {
                        $writer.Close()
                        $writer.Dispose()
                     }
                     if($reader) {
                        $reader.Close()
                        $reader.Dispose()
                     }
                  }
                  if(!$fileSuccess) { throw "Couldn't unpack to $File."}
                  if($Passthru) { Get-Item $file }
               }
               $success = $true
            } else { # !Force
               $Import = $false # Don't _EVER_ import if they refuse the install
            }        
         } # ShouldProcess
         if(!$success) { $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord (New-Object System.Management.Automation.HaltCommandException "Can't overwrite $ModuleName module: User Refused"), "ShouldContinue:False", "OperationStopped", $_) ) }
      } catch [Exception] {
         $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord $_.Exception, "Unexpected Exception", "InvalidResult", $_) )
      } finally {
         if($Package) {
            $Package.Close()
            $Package.Dispose()
         }
      }
      if($success) {
         Write-Output $ModuleResult
      }
   }
}

# Internal function: Copy data from one stream to another
# Used by Expand-Package and New-Module...
function Copy-Stream {
  #.Synopsis
  #   Copies data from one stream to another
  param(
    # The source stream to read from
    [IO.Stream]
    $reader,

    # The destination stream to write to
    [IO.Stream]
    $writer,

    [string]$Activity = "File Packing",

    [Int]
    $Length = 0
  )
  end {
    $bufferSize = 0x1000 
    [byte[]]$buffer = new-object byte[] $bufferSize
    [int]$sofar = [int]$count = 0
    while(($count = $reader.Read($buffer, 0, $bufferSize)) -gt 0)
    {
      $writer.Write($buffer, 0, $count);

      $sofar += $count
      if($Length -gt 0) {
         Write-Progress -Activity $Activity  -Status "Copied $sofar of $Length" -ParentId 0 -Id 1 -PercentComplete (($sofar/$Length)*100)
      } else {
         Write-Progress -Activity $Activity  -Status "Copied $sofar bytes..." -ParentId 0 -Id 1
      }
    }
    Write-Progress -Activity "File Packing" -ParentId 0 -Id 1 -Complete
  }
}
