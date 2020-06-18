function Check-LogonHours {
    param(
        [Parameter(Mandatory=$true,Position=1)]
        [array]$MonitorList,

        [Parameter(Mandatory=$true,Position=2)]
        [array]$NotifyEmails,

        [Parameter(Mandatory=$true,Position=3)]
        [string]$Sender,

        [Parameter(Mandatory=$true,Position=4)]
        [string]$SMTPServer,

        [Parameter(Mandatory=$false,Position=5)]
        [string]$StateFile
    )
    Begin{
        # on instantiation, this will be null, or all 0s
        $zeroLogonHours = [System.Byte[]]::CreateInstance([System.Byte],21)

        $currentState = @{}
        foreach($sam in $MonitorList){
            $user = $null
            try {
                $user = get-aduser -identity $sam -Properties logonhours | Select-Object -Property SamAccountName, logonhours
                if($null -ne $user){
                    $currentState.Add($user.SamAccountName,$user.logonhours)
                }
            }
            catch {
                Write-Verbose "$sam could not be found; skipping"
            }
        }

        try {
            $previousState = Import-Clixml -Path $StateFile -ea SilentlyContinue
        }
        catch {
            $previousState = $currentState
        }
    }
    Process{
        foreach($user in $currentState.GetEnumerator()){
            $sam = $user.Key
            if ($user.Value -ne $zeroLogonHours -and $null -ne (Compare-Object -ReferenceObject $previousState.$Sam -DifferenceObject $user.Value)){
                $parsedLogonHours = Convert-LogonHoursToHumanReadable -LogonHourAttribute $user.logonhours -Output HTML -OnlyAllowed
                Send-MailMessage -From $Sender -To $NotifyEmails -Priority High -Subject "Logon Hours Changed for $($user.SamAccountName)" -SmtpServer $SMTPServer -Body $parsedLogonHours
            }
        }
    }
    End{
        if (Test-Path $StateFile){
            Remove-Item $StateFile
        }
        Export-Clixml -Path $StateFile -InputObject $currentState -Depth 10
    }
}

function Get-ZeroLogonHourAccounts {
    param(
        [Parameter(Mandatory=$false,Position=1)]
        [string]$Domain
    )
    Begin{
        # on intantiation, this will be null, or all 0s
        $zeroLogonHours = [System.Byte[]]::CreateInstance([System.Byte],21)
        if ($Domain.Length -lt 1) {
            $Domain = (Get-ADDomain).Name
        }
    }
    Process{
        $users = get-ADUser -Filter {logonhours -eq $zeroLogonHours} -Server $Domain
    }
    End{
        return $users
    }
}

function Convert-LogonHoursToHumanReadable {
    param(
        [Parameter(Mandatory=$true,Position=1)]
        [byte[]]$LogonHourAttribute,

        [Parameter(Mandatory=$false,Position=2)]
        [ValidateSet("String","HTML","Hashtable")]
        [string]$Output = "Hashtable",

        [Parameter(Mandatory=$false,Position=3)]
        [switch]$OnlyAllowed = $false
    )

    Begin{
        # every 3 bytes corresponds to 1 day
        # each byte corresponds to 8 hours with each bit corresponding to an hour
        # If the bit is 0, login is not allowed. If 1, logon is allowed
        # 0-2 = Sunday
        # 3-5 = Monday
        # 7-9 = Tuesday
        # 10-12 = Wednesday
        # 13-15 = Thursday
        # 16-18 = Friday
        # 19-21 = Saturday

        $LogonHoursParsed = [ordered]@{}
        $days = @("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday")
        $Bias = (Get-ItemProperty -Path HKLM:\System\CurrentControlSet\Control\TimeZoneInformation).Bias
        If ($Bias -gt 10080){$Bias = $Bias - 4294967296} 
        $Bias = [Math]::Round($Bias/60, 0, [MidpointRounding]::AwayFromZero) 
    }
    Process{
        # convert all bytes to bits for hour counting
        $LogonHourBinary = ''
        foreach($byte in $LogonHourAttribute){
            $LogonHourBinary += ByteToBinaryString $byte -ReturnReversed
        }

        #adjust for local time zone, AD times stored in UTC
        If ($Bias -lt 0) 
            { 
                $Str1 = $LogonHourBinary.SubString($hourLen + $Bias,$hourLen) 
                $Str2 = $LogonHourBinary.SubString(0,$hourLen + $Bias) 
            } 
        If ($Bias -gt 0) 
        { 
            $Str1 = $LogonHourBinary.SubString(0,$Bias) 
            $Str2 = $LogonHourBinary.SubString($Bias, $LogonHourBinary.length-$Bias) 
        } 
        $localTimeHours = "$Str2$Str1"

        for($i=0; $i -lt $LogonHourAttribute.Length; $i+=3){
            $readableHours = [ordered]@{}
            #iterate over the 3 bytes of data associated with a day
            $k = 8*$i
            for($j=$k; $j -lt $k+24; $j++){
                if($localTimeHours[$j] -eq "0"){$canLogon = $false}
                else{$canLogon = $true}
                $hourIndex = $j-$k
                if($OnlyAllowed){
                    if($canLogon){
                        $readableHours.Add(("{0}-{1}" -f $hourIndex, ([int]$hourIndex+1)),$canLogon)
                    }
                }
                else{
                    $readableHours.Add(("{0}-{1}" -f $hourIndex, ([int]$hourIndex+1)),$canLogon)
                }
            }
            #add it to the correct day
            $LogonHoursParsed.Add($days[$i/3],$readableHours)
        }
    }
    End{
        switch ($Output) {
            "String" {
                $LogonHoursString = ''; 
                foreach($key in $LogonHoursParsed.Keys){
                    $LogonHoursString += "$key`n";
                    foreach($hour in $LogonHoursParsed.$key.Keys){
                        $LogonHoursString += "$hour`:"; 
                        $LogonHoursString += $LogonHoursParsed.$key.$hour; 
                        $LogonHoursString += "`n"
                    }; 
                    $LogonHoursString += "`n"
                }
                return $LogonHoursString
            }
            "HTML" {
                $LogonHoursHtml = "<head><style>table, th, td {border: 1px solid black;border-collapse: collapse;}</style></head>"
                foreach($key in $LogonHoursParsed.Keys){
                    $LogonHoursHtml += "<table><caption>$key</caption>"
                    $LogonHoursHtml += "<tr><th>Hours</th><th>CanLogon?</th></tr>"
                    foreach($hour in $LogonHoursParsed.$key.Keys){
                        $LogonHoursHtml += "<tr><td>$hour</td><td>$($LogonHoursParsed.$key.$hour)</td></tr>"
                    }; 
                    $LogonHoursHtml += "</table>"
                }
                return $LogonHoursHtml
            }
            Default {
                return $LogonHoursParsed
            }
        }
    }
}

function ByteToBinaryString {
    param(
        [Parameter(Mandatory=$true,Position=1)]
        [byte]$Byte,

        [Parameter(Mandatory=$false,Position=2)]
        [switch]$ReturnReversed=$false
    )
    Begin{
        $binaryString = ''
    }
    Process{
        if($ReturnReversed){
            for($i=0; $i -lt 8; $i++){
                if(($Byte -band (1 -shl $i)) -gt 0){
                    $binaryString += 1
                }
                else{
                    $binaryString += 0
                }
            }
        }
        else{
            for($i=7; $i -ge 0; $i--){
                if(($Byte -band (1 -shl $i)) -gt 0){
                    $binaryString += 1
                }
                else{
                    $binaryString += 0
                }
            }
        }
    }
    End{
        return $binaryString
    }
}