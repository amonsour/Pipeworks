function Invoke-Parallel
{
    <#
    .Synopsis
        Invokes PowerShell in parallel
    .Description
        Invokes PowerShell in parallel and in the same proess space.  This maximizes performance for parallel execution in PowerShell, by removing the drag associated with background processes.
    .Example
        1..10 | Invoke-Parallel -Command {                        
            (Get-Date).ToShortTimeString() + "." + (Get-Date).Millisecond                        
        } -SliceSize 1 -MaxRunning 10 

    .Example
        1..10 | Invoke-Parallel -Command {                        
            foreach ($a in $args) {
                "$a - " + ((Get-Date).ToShortTimeString() + "." + (Get-Date).Millisecond)
            }
        } 
    .Notes
        Invoke-Parallel is an alternative to using PowerShell workflows to run PowerShell in parallel.  
        
        Because PowerShell workflows involve process isolation, each workflow takes up a lot of overhead for a small operation.  
        
        This overhead is considerably increased when the workflow is expected to return information, since this information has to be deserialized and brought into the process via interprocess communication (IPC).  Doing this takes up a lot of time and requires the movement of a lot of memory, which also slows down workflows.


        Invoke-Parallel uses PowerShell RunspacePools to run code in parallel within the current process, which saves a lot of overhead.
    .Link
        Update-SQL
    #>
    [OutputType([PSObject])]
    param(
    # The list of input objects
    [Parameter(Mandatory=$true,ValueFromPipeline=$true,Position=1)]
    [PSObject[]]
    $InputObject,

    # The command
    [Parameter(Mandatory=$true,Position=0)]
    [ScriptBlock]
    $Command,

    # The size of each slice of data.  By default, this is the square root of the number of items
    [Parameter(Position=3)]
    [Uint32]
    $SliceSize,

    # The maximum number of running items.  By default, this is the square root of the slice size.
    [Parameter(Position=4)]
    [Uint32]
    $MaxRunning
    )


    begin {
        #region Declare the type
        if (-not ('StartAutomating.ParallelInvoker' -as [Type])) {
            $t = Add-Type -TypeDefinition @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace StartAutomating {
    public class ParallelInvoker {
        public ParallelInvoker() {
            combinedOutput.DataAdded += new EventHandler<DataAddedEventArgs>(outputCollection_DataAdded);
        }
        void outputCollection_DataAdded(object sender, DataAddedEventArgs e) {
            PSDataCollection<PSObject> collection = sender as PSDataCollection<PSObject>;
            if (collection != null) {
                PSObject lastOutput = collection[e.Index];
                pendingOutput.Enqueue(lastOutput);
            } else {
                // Progress record
                PSDataCollection<ProgressRecord> progressCollection = sender as PSDataCollection<ProgressRecord>;
                ProgressRecord lastProgress = progressCollection[e.Index];
                pendingOutput.Enqueue(new PSObject(lastProgress));
            }            
        }
        PSDataCollection<PSObject> combinedOutput = new PSDataCollection<PSObject>();
        Queue<PSObject> pendingOutput = new Queue<PSObject>();
        public IEnumerator<PSObject> InvokeParallel(ScriptBlock sb, PSObject[]psObject, uint maxRunning = 0, uint sliceSize = 0) 
        {
            combinedOutput.Clear();
            pendingOutput.Clear();
            List<PowerShell> runningJobs = new List<PowerShell>();
            
            if (sliceSize == 0) {
                sliceSize = (uint)System.Math.Sqrt(psObject.Length);
            }
            
            if (maxRunning == 0) {
                maxRunning = (uint)System.Math.Sqrt(sliceSize);
            }
            
            if (maxRunning == 0) {
                maxRunning = 1;
            }

            RunspacePool runspacePool = RunspaceFactory.CreateRunspacePool(1, (int)maxRunning);
            runspacePool.Open();
            uint index = 0;
            uint innerIndex = 0;
            List<PSObject> slice;
            string ssb = sb.ToString();
            for(; index<psObject.Length;index+=sliceSize) {
                slice = new List<PSObject>();
                for(innerIndex = index; innerIndex < psObject.Length && innerIndex < (index + sliceSize); innerIndex++) {
                    
                    slice.Add(psObject[innerIndex]);
                    
                }   
                
                PowerShell psCmd = PowerShell.Create();
                
                psCmd.AddScript(ssb);
                psCmd.AddParameters(slice);
                psCmd.Commands.Commands[0].MergeMyResults(PipelineResultTypes.All, PipelineResultTypes.Output);
                psCmd.RunspacePool = runspacePool;
                psCmd.Streams.Progress.DataAdded += new EventHandler<DataAddedEventArgs>(outputCollection_DataAdded);
                IAsyncResult invocation = psCmd.BeginInvoke<Object, PSObject>(null, combinedOutput);
                runningJobs.Add(psCmd);                
            }
            
            
            bool incompleteJobs = false;
            List<PowerShell> jobsToRemove = new List<PowerShell>();
            do {
                incompleteJobs = false;
                while (pendingOutput.Count > 0) {
                    yield return pendingOutput.Dequeue();
                }                
                foreach (PowerShell rj in runningJobs) {
                    if (rj.InvocationStateInfo.State != PSInvocationState.Completed && rj.InvocationStateInfo.State != PSInvocationState.Failed && rj.InvocationStateInfo.State != PSInvocationState.Stopped && rj.InvocationStateInfo.State != PSInvocationState.Disconnected) {
                        incompleteJobs = true;
                    } else {
                        if (rj.InvocationStateInfo.State == PSInvocationState.Failed && rj.InvocationStateInfo.Reason != null) {
                            yield return new PSObject(new ErrorRecord(rj.InvocationStateInfo.Reason, " ", ErrorCategory.WriteError, rj));
                        }
                        jobsToRemove.Add(rj);
                    }
                }

                foreach (PowerShell ps in jobsToRemove) {
                    runningJobs.Remove(ps);
                    ps.Dispose();
                }

                jobsToRemove.Clear();
            } while (incompleteJobs);
            

            while (pendingOutput.Count > 0) {
                yield return pendingOutput.Dequeue();
            }
            runspacePool.Close();           
            runspacePool.Dispose();           

            combinedOutput.Clear();
            combinedOutput.Dispose();
        }
    }
}
"@ -PassThru    

            $null = $t
        }

        $accumulatededInput = New-Object Collections.Generic.List[PSObject]

        #endregion Declare the type
    }
    
    process {
        #region Accumulate Input
        $null = $accumulatededInput.AddRange($InputObject)
        #endregion Accumulate Input
    }

    end {
        #region Run in parallel 
        foreach ($_ in ((New-OBject StartAutomating.ParallelInvoker).InvokeParallel($Command, $accumulatededInput.ToArray(), $MaxRunning, $SliceSize))) {
            if ($_ -is [Management.Automation.ProgressRecord]) {
                $progressParameters = @{
                    Id = $_.ActivityId
                    ParentId = $_.ParentActivityId
                    PercentComplete = $_.PercentComplete
                    Activity = $_.Activity
                    Status = $_.StatusDescription
                    SecondsRemaining = $_.SecondsRemaining
                    Completed = if ($_.RecordType -eq 'Processing') {
                        $false
                    } else {
                        $true 
                    }
                }

                if ($progressParameters.SecondsRemaining -eq -1) {
                    $progressParameters.Remove('SecondsRemaining')
                }
                if ($progressParameters.Id -eq -1) {
                    $progressParameters.Remove('Id')
                }
                if ($progressParameters.ParentId -eq -1) {
                    $progressParameters.Remove('ParentId')
                }
                if (-not $progressParameters.Completed) {
                    $progressParameters.Remove('Completed')
                }
                Write-Progress @progressParameters
            } else {
                $_
            }
        }
        #endregion Run in parallel
    }
} 