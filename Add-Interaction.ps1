function Add-Interaction
{
    <#
    .Synopsis
        Adds a user interaction to user storage
    .Description
        Adds a user interaction to user storage.  
                
        Interactions are things a user has done within a service.  
                
        For instance, you might Add-Interaction "VoteCount" 1 when someone votes on a video.


        You can use interactions for personalized statistical tracking, and you can also use interactions to control if someone can use a command.        

        
        Interactions may only contain numbers.  Interactions can only be used within a Pipeworks web site
    .Example
        $session["User"] | 
            Add-Interaction "VoteCount" 1
    .Link
        Get-Person
    .Link
        Confirm-Person
    #>
    [OutputType([Nullable], [PSObject])]
    [CmdletBinding(DefaultParameterSetName='ChangeInteraction')]
    param(
    # The object that is being interacted with,
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
    [PSObject]
    $InputObject,

    # The name of the interaction
    [Parameter(Mandatory=$true,Position=0,ValueFromPipelineByPropertyName=$true,ParameterSetName='ChangeInteraction')]
    [string]
    $InteractionName,

    # The amount the interaction has changed.
    [Parameter(Position=1,ValueFromPipelineByPropertyName=$true, ParameterSetName='ChangeInteraction')]
    [double]
    $Change = 1,

    # If set, the interaction count will be set to the change, instead of added to the change.
    [Parameter(ValueFromPipelineByPropertyName=$true, ParameterSetName='ChangeInteraction')]
    [Switch]
    $ResetInteractionCount,


    # The name of the award that will be given to the object
    [Parameter(ValueFromPipelineByPropertyName=$true,ParameterSetName='AddAward',Mandatory=$true)]
    [Parameter(ValueFromPipelineByPropertyName=$true,ParameterSetName='RemoveAward',Mandatory=$true)]
    [string]
    $AwardName,

    # If set, the award will be removed from the object, instead of added to it.
    [Parameter(ValueFromPipelineByPropertyName=$true,ParameterSetName='RemoveAward',Mandatory=$true)]
    [Switch]
    $RemoveAward,
    
    # If set, will output the modified object.
    [Switch]
    $PassThru   
    )

    process {
        $shouldCommit  = $false 
        if ($PSCmdlet.ParameterSetName -eq 'AddAward') {
            
            $awardsList = @($InputObject.Awards -split ';' -ne '')
            $oldAwardsCount = $awardsList.Count
            $awardsList = @($awardsList) + $AwardName
            $awardsList = @($awardsList | Select-Object -Unique | Sort-Object)
            $awardsText = $awardsList -join ';'
            $InputObject | Add-member NoteProperty Awards $awardsText -Force 
            $newAwardsCount = $awardsList.Count
            if ($newAwardsCount -ne $oldAwardsCount) {
                $shouldCommit = $true
            }
        } elseif ($PSCmdlet.ParameterSetName -eq 'RemoveAward') {
            $awardsList = @($InputObject.Awards -split ';' -ne '')
            $oldAwardsCount = $awardsList.Count
            $awardsList = @($awardsList | Where-Object {$_ -ne $AwardName })
            $newAwardsCount = $awardsList.Count
            $awardsText = @($awardsList | Select-Object -Unique | Sort-Object) -join ';'
            $InputObject | Add-member NoteProperty Awards $awardsText -Force 

            if ($oldAwardsCount -ne $newAwardsCount) {
                $shouldCommit = $true
            }
        } elseif ($PSCmdlet.ParameterSetName -eq 'ChangeInteraction') {
            $interactionTable = if ($InputObject.InteractionCount) {
                ConvertFrom-StringData -StringData "$($InputObject.InteractionCount)".Replace(":", "=")
            } else {
                @{}
            }


            if (-not $interactionTable[$InteractionName]) {
                $interactionTable[$InteractionName] = $Change
            } else {
                if ($ResetInteractionCount) {
                    $interactionTable[$InteractionName] = $Change
                } else {
                    $interactionTable[$InteractionName] = ($interactionTable[$InteractionName] -as [double]) + $Change
                }
            }
         
            $Interactions =
                @(foreach ($kv in $interactionTable.GetEnumerator() | Sort-Object Key) {
                    "$($kv.Key):$($kv.Value)"
                }) -join ([Environment]::NewLine)
         
            $InputObject |
                Add-Member NoteProperty InteractionCount $Interactions -Force 
            $shouldCommit = $true
        }


        #region Commit Changes if needed
        if ($shouldCommit) {
            if ($StorageAccount -and $StorageKey) {
                if (-not $TableName) {
                    $TableName = $InputObject.TableName
                }
                $InputObject | Update-AzureTable -StorageAccount $StorageAccount -StorageKey $StorageKey -TableName $TableName -Value { $_ } 
            } elseif ($ConnectionString) {
                $InputObject | Update-Sql -TableName $TableName -ConnectionStringOrSetting $ConnectionString
            } else {
                if ($InputObject.partitionKey -and $InputObject.RowKey -and $InputObject.TableName) {                
                    $InputObject | Update-AzureTable -Value { $_ } -TableName $InputObject.TableName    
                } elseif ($InputObject.getParentRow -and $pipeworksManifest.UserDB.Name) {
                    $InputObject | Update-Sql  -TableName $pipeworksManifest.UserDb.Name
                }
            }
        }
        #endregion Commit Changes if needed


        if ($passthru) {
            $InputObject
        }
    }
} 
