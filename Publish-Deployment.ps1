function Publish-Deployment
{
    <#
    .Synopsis
        Publishes a deployment
    .Description
        Generates an Azure deployment package from a set of modules that will be deployed.

        OR

        Uploads a set of modules in a deployment to Blob Storage

    .Link
        Get-Deployment
    .Link
        Add-Deployment
    .Link
        Remove-Deployment
    .Link
        Import-Deployment
    .Example
        Publish-Deployment
    #>
    [CmdletBinding(DefaultParameterSetName="PublishAzureDeployment")]
    [OutputType([IO.FileInfo], [Nullable])]
    param(
    # The directory the deployment will be placed in.
    [Parameter(ParameterSetName='PublishAzureDeployment', ValueFromPipelineByPropertyName=$true)]
    [string]
    $DeploymentDirectory = "$home\Documents\Deployments",


    # The directory the deployment will be placed in.
    [Parameter(ParameterSetName='PublishAzureDeployment', ValueFromPipelineByPropertyName=$true)]
    [string]
    $DeploymentName,

    # The name of the modules to publish
    [Parameter(Position=0)]
    [string[]]
    $Name,

    # The group of modules to publish
    [Parameter(Position=1)]
    [string[]]
    $Group,

    # A list of groups to exclude.
    [Parameter(Position=2)]
    [string[]]
    $ExcludeGroup,


    # The VMSize of the deployment
    [Parameter(ParameterSetName='PublishAzureDeployment', ValueFromPipelineByPropertyName=$true)]
    [ValidateSet('ExtraSmall','Small','Medium', 'Large', 'Extra-Large', 'XS', 'XL', 'S', 'M', 'L')]
    [string]
    $VMSize = 'ExtraSmall',

    # The instance count
    [Parameter(ParameterSetName='PublishAzureDeployment', ValueFromPipelineByPropertyName=$true)]
    [Uint32]
    $InstanceCount = 1,
    
    # If set, will publish items in a background job
    [Switch]
    $AsJob,

    # If set, will wait for all jobs to complete
    [Switch]
    $Wait,

    # The throttle for background jobs.  By default, 10
    [Uint32]
    $Throttle,

    # The buffer between jobs.  By default, 3 seconds
    [Timespan]
    $Buffer = $([Timespan]::FromSeconds(3)),

    # The operating system family
    [Parameter(ParameterSetName='PublishAzureDeployment', ValueFromPipelineByPropertyName=$true)]
    [ValidateSet("2K8R2","2012")]
    [string]
    $Os = "2012",

    # The Azure storage account 
    [Parameter(Mandatory=$true,ParameterSetName='PublishToBlobStorage', ValueFromPipelineByPropertyName=$true)]
    [string]
    $StorageAccount,

    # The Azure storage key
    [Parameter(Mandatory=$true,ParameterSetName='PublishToBlobStorage', ValueFromPipelineByPropertyName=$true)]
    [string]
    $StorageKey,
    
    # If set, will push a deployment to a list of computers via a LAN.
    [Parameter(Mandatory=$true,ParameterSetName='PublishToLan', ValueFromPipelineByPropertyName=$true)]
    [Parameter(ParameterSetName='PublishToAzureVM', ValueFromPipelineByPropertyName=$true)]
    [string[]]
    $ComputerName,

    # If set, will publish a deployment to AzureVMs
    [Parameter(Mandatory=$true,ParameterSetName='PublishToAzureVM')]
    [Switch]
    $ToAzureVM,

    # The name of the computers that will receive the deployment
    [Parameter(Mandatory=$true,ParameterSetName='PublishToAzureVM', ValueFromPipelineByPropertyName=$true)]
    [Parameter(Mandatory=$true,ParameterSetName='PublishToLan', ValueFromPipelineByPropertyName=$true)]
    [Management.Automation.PSCredential]
    $Credential,

    # The number of concurrent batches of remote jobs to run.   This should approximately be the number of remote shells allowed on the destination machines.
    [Parameter(ParameterSetName='PublishToAzureVM')]
    [Uint32]
    $BatchSize = 5,
    
    # The secure settings to copy to the remote machine.  Wildcards are permitted.
    [Parameter(ParameterSetName='PublishToAzureVM')]
    [Parameter(ParameterSetName='PublishToLan')]
    [string[]]
    $SecureSetting   

    )
    begin {
        $deployments = Get-Deployment
        #region RunAs Job or Elevated
        $asJobOrElevate = {
            param($CommandInfo, [switch]$OnlyCommand, [string[]]$AdditionalModules, [Hashtable]$Parameter, [Switch]$RequireAdmin)
            
            # Find the current user and see if they're admin
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
            $isAdmin = (New-Object Security.Principal.WindowsPrincipal $currentUser).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
            

            # If we need to run in the background...
            if ($AsJob -or $Throttle -or (-not $isAdmin) -and $requireAdmin) {                           
                # Then pack things up...
                if ($onlyCommand) {     
                    # Just drop in the command if it's simple        
                    $AdditionalModules = $AdditionalModules | Select-Object -Unique
                    $myDefinition = [ScriptBLock]::Create("
$(if ($AdditionalModules) {
"
    Import-Module '$($AdditionalModules -join ("','"))'
"})
                    
function $commandInfo {
$($commandInfo | Select-Object -ExpandProperty Definition)
}

")                        
                } else {
                    # Otherwise, drop in the module import
                    $myModule = $CommandInfo.ScriptBlock.Module

                    $AdditionalModules += $myModule | Split-Path
                    $AdditionalModules += $myModule.RequiredModules | Split-Path
                    $AdditionalModules = $AdditionalModules | Select-Object -Unique
                    $myDefinition = [ScriptBLock]::Create("

$(if ($AdditionalModules) {
"
    Import-Module '$($AdditionalModules -join ("','"))'
"})

")                   
                }

            # Remove AsJob, Throttle, and RequireAdmin (to avoid endless loops)
            $null = $Parameter.Remove('AsJob')                                    
            $null = $Parameter.Remove('Throttle')
            $null = $Parameter.Remove('RequireAdmin')                                    
            # Create the full command.  Use Splatting to provide the parameters
            $myJob= [ScriptBLock]::Create("" + {                        
param([Hashtable]$parameter)                         
                                    
} + $myDefinition + "                        
                                    
            $commandInfo `@parameter                        
")      


            
            if ($Throttle) {
                # Throttle as needed
                $jobLaunched=  $false
                
                do {
                    if ($myJobs) {
                        $myJobs | 
                            Receive-Job
                    }

                    
                    $runningJobs = $myJobs | 
                        Where-Object { $_.State -ne 'Running' }
if ($runningJobs) {
                        $runningJobs | 
                            Remove-Job -Force
                    }
                
                    

                    if ($myJobs.Count -lt $throttle) {
                        $null = Start-Job -Name "${MyCmd}_Background_Job" -ScriptBlock $myJob -ArgumentList $Parameter
                        $JobLaunched = $true
                    }

                    $myJobs =  Get-Job -Name "${MyCmd}_Background_Job" -ErrorAction SilentlyContinue
                    Write-Progress "Waiting for Jobs to Complete" "$($myJobs.Count) Running" -Id $ProgressId  
                } until ($jobLaunched)
                
                $myJobs =  Get-Job -Name "${MyCmd}_Background_Job" -ErrorAction SilentlyContinue
                $myJobs  | 
                    Wait-Job | 
                    Receive-Job
                return 
            } elseif ($asJob) {
                # Just kick off the background job
                return Start-Job -ScriptBlock $myJob -ArgumentList $Parameter -Name "${CommandInfo}_Background_Job"
                
            } elseif ((-not $isAdmin) -and $RequireAdmin) {
                # Create a new process to run the job
                $fullCommand = 
"
`$parameter = $(Write-PowerShellHashtable -InputObject $parameter)
& { $myJob } `$parameter

"

                $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fullCommand))


                return  Start-Process powershell -Verb Runas -ArgumentList '-encodedCommand', $encodedCommand -PassThru
                
            }
        }
        }
        #endregion RunAs Job or Elevated
    }
    process {        
        $deploymentsToPublish = $deployments | Where-Object { 
            if ($name) {
                $_.Name -like $name
            } elseif ($Group) {
                if ($ExcludeGroup) {
                    foreach ($g in $Group) {
                        if ($_.Group -contains $g) {
                            $excluded = 
                                foreach ($ex in $ExcludeGroup) {
                                    if ($_.Group -contains $ex) {
                                        $true
                                        break
                                    }
                                }                                
                            if (-not $excluded) {
                                $_
                            }
                        }
                    }                    
                } else {
                    foreach ($g in $Group) {
                        if ($_.Group -contains $g) {
                            $_
                        }
                    }
                }
                    
            } elseif ($ExcludedGroup) {
                $excluded = 
                    foreach ($ex in $ExcludeGroup) {
                        if ($_.Group -contains $ex) {
                            $true
                            break
                        }
                    }
                if (-not $excluded) { $true }   
            } else {
                $true
            }
        }
        if ($PSCmdlet.ParameterSetName -eq 'PublishAzureDeployment') {
            $launched = . $asJobOrElevate $MyInvocation.MyCommand -additionalModules $theModulePaths -Parameter $psBoundParameters -RequireAdmin
            $null = $launched
            

            

            if (-not $psBoundParameters.DeploymentName) {
                $DeploymentName = if ($Name) {
                    $name 
                } elseif ($Group) {
                    $group 
                } else {
                    "MyPipeworksDeployment"
                }
            }

            

            $deploymentsToPublish | 
                Import-Deployment |                  
                Publish-AzureService -DeploymentName $deploymentName -DeploymentDirectory $DeploymentDirectory -VMSize $vmSize -InstanceCount $InstanceCount -Os $os -AsJob -Wait
        } elseif ($PSCmdlet.ParameterSetName -eq 'PublishToBlobStorage') {
            
            $jobs = @()
            $deploymentsToPublish | 
                Import-Deployment | 
                ForEach-Object {
                    
                    $item = $_

                    if ($asjob) {
                        $jobs += Start-Job -ArgumentList $item, $storageAccount, $storageKey -ScriptBlock {
                            param($item, $storageAccount, $storageKey) 

                            Import-Module Pipeworks -Force

                            $item | 
                                Split-Path | 
                                Get-ChildItem -Recurse |         
                                Out-Zip -ZipFile $home\Documents\WindowsPowerShell\LatestDeployment\$($item.Name).zip    


                            $zipFile = Get-Item "$home\Documents\WindowsPowerShell\LatestDeployment\$($item.Name).zip"

                            Get-Item $zipFile | 
                                Export-Blob -StorageAccount $StorageAccount -StorageKey $StorageKey -Container "$($zipFile.Name.Replace(' ', '').Replace('.zip', '').Replace('.', ''))-Source" -Name "$([DateTime]::Now.ToShortDateString().Replace('/', '-')).zip"                                     
                        }    

                        #Start-Sleep -Milliseconds 100

                    } else {
                        $item | 
                            Split-Path | 
                            Get-ChildItem -Recurse |         
                            Out-Zip -ZipFile $home\Documents\WindowsPowerShell\LatestDeployment\$($item.Name).zip    


                        $zipFile = Get-Item "$home\Documents\WindowsPowerShell\LatestDeployment\$($item.Name).zip"

                        Get-Item $zipFile | 
                            Export-Blob -StorageAccount $StorageAccount -StorageKey $StorageKey -Container "$($zipFile.Name.Replace(' ', '').Replace('.zip', '').Replace('.', ''))-Source" -Name "$([DateTime]::Now.ToShortDateString().Replace('/', '-')).zip"                                     
                    }

                    
                    
                }

            if ($Wait) {
                $runningJobs = @($jobs)
                while ($runningJobs.Count) {
                    if ($jobs) {
                        $jobs | 
                            Receive-Job
                    }

                    
                    $runningJobs = @($jobs | 
                        Where-Object { $_.State -eq 'Running' })

                   
                    
                                        
                    Write-Progress "Waiting for Jobs to Complete" "$($runningJobs.Count) Running"
                }
            } else {
                $jobs
            }
            
        } elseif ($PSCmdlet.ParameterSetName -eq 'PublishToAzureVM' -or $PSCmdlet.ParameterSetName -eq 'PublishToLan') {
            Import-Module Azure -Global

            if ($PSCmdlet.ParameterSetName -eq 'PublishToAzureVM') {
                $vmList = @(Get-AzureVM | ForEach-Object { $_.Name + ".CloudApp.net" } )
                if ($ComputerName) {
                    $computerName = foreach ($v in $vmList) {
                        foreach ($cn in $ComputerName) {
                            if ($v -like $cn) {
                                $v
                            }
                        }    
                    }
                    $ComputerName = $ComputerName | Select-Object -Unique
                } else {
                    $computerName = $vmList
                }

            }
            
            $deploymentsToPublish | 
                Import-Deployment |
                ForEach-Object -Begin {
$sb = {
    param([string]$moduleName, [byte[]]$moduleZipBytes) 
    Add-Type -AssemblyName System.Web


    $destModuleDir = "$env:UserProfile\Documents\WindowsPowerShell\Modules\$($moduleName)"
    
    $tempDir = [IO.Path]::GetTempPath()    
    $theFile = Join-Path $tempDir "$($moduleName)$(Get-Random).zip"
     
    

    [IO.FILE]::WriteAllBytes("$theFile", $moduleZipBytes)
    
}.ToString() + @"
function Expand-Zip {
    $((Get-Command Expand-Zip).Definition)
}
"@ + {
    if (Test-Path $destModuleDir) {
        $destModuleDir | Remove-Item -Recurse -Force
    }        

    $null = New-Item -ItemType Directory -path $destModuleDir -ErrorAction SilentlyContinue

    Expand-Zip -ZipPath "$theFile" -OutputPath $destModuleDir

    Remove-Item -Path "$theFile" -Force
}

$syncScript = [ScriptBlock]::Create($sb)
                    $jobs = @()
                } -Process {
                    $tempFile = Join-Path $env:TEMP "$($_.Name)$(Get-Random).zip"
                    $module = $_
                    $module | 
                        Split-Path | 
                        Get-ChildItem -Recurse -Force | 
                        Out-Zip -ZipFile $tempFile


                    $zipBytes = [IO.File]::ReadAllBytes($tempFile)

                    $jobs += 
                        foreach ($cn in $ComputerName) {
                            Invoke-Command -ComputerName $cn -Credential $Credential -Authentication Credssp -ScriptBlock $syncScript -AsJob -JobName $_.Name -ArgumentList $module.Name, $zipBytes
                        }
                    
                    $runningJobs = @($jobs | Where-Object {$_.State -eq 'Running' })

                    $maxRunning = $runningJobs | Group-Object ComputerName -NoElement | Sort-Object Count -Descending | Select-Object -First 1 -ExpandProperty Count

                    if ($maxRunning -ge $BatchSize) {
                        while ($jobs | Where-Object { $_.State -eq 'Running'}) {
                            $jobs | Receive-Job
                            Start-Sleep -milliseconds 250
                        }
                    }

                    Remove-Item -Path $tempFile -Force

                } -End {
                    while ($jobs | Where-Object { $_.State -eq 'Running'}) {
                        $jobs | Receive-Job
                        Start-Sleep -milliseconds 250
                    }
                }


            if ($SecureSetting) {
                $settings = @(foreach ($s in $SecureSetting) {
                    Get-SecureSetting $s -Decrypted
                })
                
                $settings |
                        ForEach-Object -Begin {
                            $setecAstronomy = ""
                        } {
                            $s = $_
                            if (-not $s.Name) { continue } 
                            if ($s.Type -eq [string]) {
                                $setecAstronomy += "Add-SecureSetting -Name '$($s.Name)' -String '$($s.DecryptedData.Replace("'", "''"))'
"
                            } elseif ($s.Type -eq [Hashtable]) {
                                $setecAstronomy += "
`$data = $($s.DecryptedData | Write-PowershellHashtable)
Add-SecureSetting -Name '$($s.Name)' -Hashtable `$data
"
                            } elseif ($s.Type -eq [Management.Automation.PSCredential]) {
                                $setecAstronomy += "
`$p = ConvertTo-SecureString -String '$($s.DecryptedData.GetNetworkCredential().Password.Replace("'", "''"))' -AsPlainText -Force
Add-SecureSetting -Name '$($s.Name.Replace("_Password", ''))' -Credential (New-Object Management.Automation.PSCredential '$($s.DecryptedData.UserName.Replace("'", "''"))', `$p)
"
                            
                            }
                        } -End {
                            
                        }
                $setecAstronomy = [ScriptBlock]::Create("
Import-Module Pipeworks
$setecAstronomy
")
                            $jobs += 
                                foreach ($cn in $ComputerName) {
                                    Invoke-Command -ComputerName $cn -Credential $Credential -Authentication Credssp -ScriptBlock $setecAstronomy -AsJob -JobName "SetecAstronomy"
                                }
                            while ($jobs | Where-Object { $_.State -eq 'Running'}) {
                                $jobs | Receive-Job
                                Start-Sleep -milliseconds 250
                            }
            }
        }
    } 
}

