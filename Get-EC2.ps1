function Get-EC2
{
    <#
    .Synopsis
        Gets EC2 Instances
    .Description
        Gets EC2 instances from AWS
    .Example
        Get-EC2
    .Link
        Add-EC2
    .Link
        Reset-EC2
    .Link
        Remove-EC2
    #>
    [CmdletBinding(DefaultParameterSetName='GetAll')]
    param(
    # The name of the EC2 instance
    [Parameter(Mandatory=$true,
        ParameterSetName='ByName',
        ValueFromPipeline=$true)]
    [string]
    $Name,
    
    # The EC2 instance ID
    [Parameter(Mandatory=$true,
        ParameterSetName='ById',
        ValueFromPipelineByPropertyName=$true)]
    [string]
    $InstanceId
    )
    
    process {
        if (-not $AwsConnections) { 
            return
        }
        $AwsConnections.EC2.DescribeInstances((New-Object Amazon.EC2.Model.DescribeInstancesRequest)).DescribeInstancesResult.Reservation | 
            Select-Object -ExpandProperty RunningInstance |
            Where-Object {
                # Skip EC2 instances that are terminated or terminating
                if ($_.InstanceState.Name -like "*terminat*") { return } 
                if ($psboundParameters.Name ) {
                    if ($_.KeyName -like $name) {
                        $true
                    }                    
                } elseif ($psBoundparameters.InstanceId) {
                    if ($_.InstanceId -eq $InstanceId) {
                        $true
                    }                    
                } else {
                    $true
                }
            }
        
    }
} 
