.{
  #.Synopsis
  #   Installs the PoshCode Packaging module
  #.Example
  #   iex (iwr http://PoshCode.org/Install).Content
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
  param(
    # The path to a package to download
    [Parameter()]
    $Url = "http://PoshCode.org/Packaging.psmx"
  )
  end {
    # If the script isn't running from a module, then run the install
    if(!$MyInvocation.MyCommand.Module) {
      Write-Progress "Installing " -Id 0

      $InstallPath = Select-ModulePath
      Write-Verbose "Selected module install path: $InstallPath"

      $PackageFile = Get-ModulePackage $Url $InstallPath
      Write-Verbose "Downloaded module package: $PackageFile"

      Install-ModulePackage $PackageFile $InstallPath -Import
    }
  }

  begin {
    Add-Type -Assembly WindowsBase, PresentationFramework

    function Get-ModulePackage {
      #.Synopsis
      #   Download the module package to a local path
      [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
      param(
        # The path to a package to download
        [Parameter(Position=0)]
        [string]$Url = "http://PoshCode.org/Packaging.psmx",

        # The PSModulePath to install to
        [Parameter(ParameterSetName="InstallPath", Mandatory=$true, Position=1)]
        [Alias("PSModulePath")]
        $InstallPath,

        # If set, the module is installed to the Common module path (as specified in Packaging.ini)
        [Parameter(ParameterSetName="CommonPath", Mandatory=$true)]
        [Switch]$Common,

        ##### We do not support installing to the System location. #####
        # # If set, the module is installed to the System module path (as specified in Packaging.ini)
        # [Parameter(ParameterSetName="SystemPath", Mandatory=$true)]
        # [Switch]$System,

        # If set, the module is installed to the User module path (as specified in Packaging.ini)
        [Parameter(ParameterSetName="UserPath")]
        [Switch]$User
      )

      begin {
        if($PSCmdlet.ParameterSetName -ne "InstallPath") {
          $Config = Get-ConfigData
          switch($PSCmdlet.ParameterSetName){
            "UserPath"   { $InstallPath = $Config.UserPath }
            "CommonPath" { $InstallPath = $Config.CommonPath }
            # "SystemPath" { $InstallPath = $Config.SystemPath }
          }
          $PsBoundParameters.Remove(($PSCmdlet.ParameterSetName + "Path")) | Out-Null
          $PsBoundParameters.Add("InstallPath", $InstallPath) | Out-Null
        }
      }
      end {
        if(Get-Command Packaging\Invoke-Web -ErrorAction SilentlyContinue) {
          Write-Verbose "Using Invoke-Web"
          Packaging\Invoke-Web $Url -OutFile $InstallPath
        } else {
          Write-Verbose "Manual Download (missing Invoke-Web)"
          try {
          # Get the Packaging package from the web

            $Reader = [Net.WebRequest]::Create($Url).GetResponse().GetResponseStream()
            $PackagePath = Join-Path $InstallPath (Split-Path $Url -leaf)
            $Writer = [IO.File]::Open($PackagePath, "Create", "Write" )

            Copy-Stream $reader $writer -Activity "Downloading $Url"
            Get-Item $PackagePath
          } catch [Exception] {
            $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord $_.Exception, "Unexpected Exception", "InvalidResult", $_) )
            Write-Error "Could not download package from $Url"
          } finally {
            $Reader.Close()
            $Reader.Dispose()
            if($Writer) {
              $Writer.Close()
              $Writer.Dispose()
            }
          }
        }
      }
    }

    function Install-ModulePackage {
      [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium", DefaultParameterSetName="UserPath")]
      param(
        # The package file to be installed
        [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, Mandatory=$true, Position=0)]
        [Alias("PSPath","PackagePath")]
        $Package,

        # The PSModulePath to install to
        [Parameter(ParameterSetName="InstallPath", Mandatory=$true, Position=1)]
        [Alias("PSModulePath")]
        $InstallPath,

        # If set, the module is installed to the Common module path (as specified in Packaging.ini)
        [Parameter(ParameterSetName="CommonPath", Mandatory=$true)]
        [Switch]$Common,

        ##### We do not support installing to the System location. #####
        # # If set, the module is installed to the System module path (as specified in Packaging.ini)
        # [Parameter(ParameterSetName="SystemPath", Mandatory=$true)]
        # [Switch]$System,

        # If set, the module is installed to the User module path (as specified in Packaging.ini)
        [Parameter(ParameterSetName="UserPath")]
        [Switch]$User,

        # If set, overwrite existing modules without prompting
        [Switch]$Force,

        # If set, the module is imported immediately after install
        [Switch]$Import,

        # If set, output information about the files as well as the module 
        [Switch]$Passthru
      )
      begin {
        if($PSCmdlet.ParameterSetName -ne "InstallPath") {
          $Config = Get-ConfigData
          switch($PSCmdlet.ParameterSetName){
            "UserPath"   { $InstallPath = $Config.UserPath }
            "CommonPath" { $InstallPath = $Config.CommonPath }
            # "SystemPath" { $InstallPath = $Config.SystemPath }
          }
          $PsBoundParameters.Remove(($PSCmdlet.ParameterSetName + "Path"))
          $PsBoundParameters.Add("InstallPath", $InstallPath)
        }

        $RejectAllOverwrite = $false;
        $ConfirmAllOverwrite = $false;
      }
      process {
        try {
          # Open it as a package
          $PackagePath = Resolve-Path $Package -ErrorAction Stop
          $Package = [System.IO.Packaging.Package]::Open( $PackagePath, "Open", "Read" )
          Write-Host ($Package.PackageProperties|Select-Object Title,Version,@{n="Guid";e={$_.Identifier}},Creator,Description, @{n="Package";e={$PackagePath}}|Out-String)

          $ModuleName = $Package.PackageProperties.Title
          $InstallPath = "$InstallPath".TrimEnd("\")
          if($InstallPath -match ([Regex]::Escape($ModuleName)+'$')) {
            $InstallPath = Split-Path $InstallPath
          }
        
          if($PSCmdlet.ShouldProcess("Extracting the module '$ModuleName' to '$InstallPath\$ModuleName'", "Extract '$ModuleName' to '$InstallPath\$ModuleName'?", "Installing $($ModuleName)" )) {
            if($Force -Or !(Test-Path "$InstallPath\$ModuleName" -ErrorAction SilentlyContinue) -Or $PSCmdlet.ShouldContinue("The module '$InstallPath\$ModuleName' already exists, do you want to replace it?", "Installing $ModuleName", [ref]$ConfirmAllOverwrite, [ref]$RejectAllOverwrite)) {

              $null = New-Item -Type Directory -Path "$InstallPath\$ModuleName" -Force -ErrorVariable FailMkDir
              
              ## Handle the error if they asked for -Common and don't have permissions
              if($FailMkDir -and @($FailMkDir)[0].CategoryInfo.Category -eq "PermissionDenied") {
                throw "You do not have permission to install a module to '$InstallPath\$ModuleName'. You may need to be elevated."
              }

              foreach($part in $Package.GetParts() | where Uri -match ("^/" + $ModuleName)) {
                # Copy the data to the file system
                try {
                  if(!(Test-Path ($Folder = Split-Path ($File = Join-Path $InstallPath $Part.Uri)) -EA 0) ){
                    $null = New-Item -Type Directory -Path $Folder -Force
                  }
                  Write-Verbose "Unpacking $File"
                  $writer = [IO.File]::Open( $File, "Create", "Write" )
                  $reader = $part.GetStream()

                  Copy-Stream $reader $writer -Activity "Writing $file"
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
                if($Passthru) { Get-Item $file }
              }
            } else { # !Force
              $Import = $false # Don't _EVER_ import if they refuse the install
            }
          } # ShouldProcess
        } catch [Exception] {
          $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord $_.Exception, "Unexpected Exception", "InvalidResult", $_) )
        } finally {
          $Package.Close()
          $Package.Dispose()
        }
        if($Import) {
          Import-Module $ModuleName -Passthru:$Passthru
        } else {
          Get-Module $ModuleName
        }      
      }
    }

    ##### Private functions ######
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

    function Select-ModulePath {
      #.Synopsis
      #   Interactively choose (and validate) a folder from the Env:PSModulePath
      [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
      param(
        # The folder to install to. This folder should be one of the ones in the PSModulePath, NOT a subfolder.
        $InstallPath
      )
      end {
        $ChoicesWithHelp = @()
        [Char]$Letter = "A"
        $default = -1
        $index = -1
        switch -Wildcard ($Env:PSModulePath -split ";") {
          "${PSHome}*" {
            ##### We do not support installing to the System location. #####
            #$index++
            #$ChoicesWithHelp += New-Object System.Management.Automation.Host.ChoiceDescription "S&ystem", $_
            continue
          }
          "$(Split-Path $PROFILE)*" {
            $index++
            $ChoicesWithHelp += New-Object System.Management.Automation.Host.ChoiceDescription "&Profile", $_
            $default = $index
            continue
          }
          "$([Environment]::GetFolderPath("CommonProgramFiles"))\Modules*" {
            $index++
            $ChoicesWithHelp += New-Object System.Management.Automation.Host.ChoiceDescription "&Common", $_
            if($Default -lt 0){$Default = $index}
            continue
          }          
          "$([Environment]::GetFolderPath("MyDocuments"))\*" { 
            $index++
            $ChoicesWithHelp += New-Object System.Management.Automation.Host.ChoiceDescription "&MyDocuments", $_
            if($Default -lt 0){$Default = $index}
            continue
          }
          default {
            $index++
            $Key = $_ -replace [regex]::Escape($Env:USERPROFILE),'~' -replace "((?:[^\\]*\\){2}).+((?:[^\\]*\\){2})",'$1...$2'
            $ChoicesWithHelp += New-Object System.Management.Automation.Host.ChoiceDescription "&$Letter $Key", $_
            $Letter = 1 + $Letter
            continue
          }
        }

        $ChoicesWithHelp += New-Object System.Management.Automation.Host.ChoiceDescription "&Other", "Type in your own path!"

        while(!$InstallPath -or !(Test-Path $InstallPath)) {
          if($InstallPath -and !(Test-Path $InstallPath)){
            if($PSCmdlet.ShouldProcess(
              "Verifying module install path '$InstallPath'", 
              "Create folder '$InstallPath'?", 
              "Creating Module Install Path" )) {

              $null = New-Item -Type Directory -Path $InstallPath -Force -ErrorVariable FailMkDir
            
              ## Handle the error if they asked for -Common and don't have permissions
              if($FailMkDir -and @($FailMkDir)[0].CategoryInfo.Category -eq "PermissionDenied") {
                Write-Warning "You do not have permission to install a module to '$InstallPath\$ModuleName'. You may need to be elevated. (Press Ctrl+C to cancel)"
              } 
            }
          }

          if(!$InstallPath -or !(Test-Path $InstallPath)){
            $Answer = $Host.UI.PromptForChoice(
              "Please choose an install path.",
              "Choose a Module Folder (use ? to see full paths)",
              ([System.Management.Automation.Host.ChoiceDescription[]]$ChoicesWithHelp),
              $Default)

            if($Answer -ge $index) {
              $InstallPath = Read-Host ("You should pick a path that's already in your PSModulePath. " + 
                                        "To choose again, press Enter.`n" +
                                        "Otherwise, type the path for a 'Modules' folder you want to create")
            } else {
              $InstallPath = $ChoicesWithHelp[$Answer].HelpMessage
            }
          }
        }

        return $InstallPath
      }
    }

    function Test-ExecutionPolicy {
      #.Synopsis
      #   Validate the ExecutionPolicy
      param()

      $Policy = Get-ExecutionPolicy
      if(([Microsoft.PowerShell.ExecutionPolicy[]]"Restricted","Default") -contains $Policy) {
        $Warning = "Your execution policy is $Policy, so you will not be able import script modules."
      } elseif(([Microsoft.PowerShell.ExecutionPolicy[]]"Unrestricted","RemoteSigned") -contains $Policy) {
        $Warning = "Your execution policy is $Policy, if modules are flagged as internet, you'll be warned before importing them."
      } elseif(([Microsoft.PowerShell.ExecutionPolicy[]]"AllSigned") -eq $Policy) {
        $Warning = "Your execution policy is $Policy, if modules are not signed, you won't be able to import them."
      }
      if($Warning) {
        Write-Warning ("$Warning`n" +
            "You may want to change your execution policy to RemoteSigned, Unrestricted or even Bypass.`n" +
            "`n" +
            "        PS> Set-ExecutionPolicy RemoteSigned`n" +
            "`n" +
            "For more information, read about execution policies by executing:`n" +
            "        `n" +
            "        PS> Get-Help about_execution_policies`n")
      }
    }

  } 
}