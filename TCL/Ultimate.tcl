
package provide Ultimate 1.6
set revision 7

#AR 19.07.2018
#set socket to non-blocking and added catch-block for disconnect (TCL-79)
#added encoding for CMark 4.x systems (TCL-78)
#optimzed getstatuscode for order

# Variables
set inputMapping [list "\\$::receiveDelimiter" \006]
set sendMapping [list \006 "$::receiveDelimiter" "<" "&lt;" "&" "&amp;"]
set commandSendMapping [list \006 "$::receiveDelimiter"]
set commandOutputMapping [list $::sendDelimiter "\\$::sendDelimiter" "\r" "" "\n" ""]
set outputMapping [list "$::sendDelimiter" "\\$::sendDelimiter" "&lt;" "<" "&gt;" ">" "&amp;" "&"]

set roVarTypes [list "Prompt" "SerialNumber" "Date" "Time"]
set rwVarTypes [list "Prompt" "SerialNumber"]

set varListSync {}
set asyncClients {}
set previousState ""
set markErrorOccured 0
set isProcessing 0
set clientcommandqueue 0
set clientcommandlist {}

proc cServerAccept {client addr port} {
	Debug "Sync client connected: $client" 3
	fileevent $client readable "cInputEvent $client"
	fconfigure $client -buffering line -translation crlf -encoding utf-8
}

proc cServerAcceptAsync {client addr port} {
	Debug "Async client connected: $client" 3
	lappend ::asyncClients $client
	
	fileevent $client readable "cInputEventAsync $client"
	fconfigure $client -buffering line -translation crlf -blocking 0 -encoding utf-8
}

proc cServerAcceptKill {client addr port} {
	Debug "Ultimate killed: $client" 1
	set ::forever 1
}

proc cInputEventAsync {client} {
	if {$client != 0} {
		gets $client data
	
		if {[eof $client]} {
			Debug "Async client closed connection: $client" 3
			set ::asyncClients [lremove $::asyncClients $client]
			script {close $client}
		}
	}
}

proc cInputEvent {client} {
	gets $client data
	
	if {[eof $client]} {
		Debug "Sync client closed connection: $client" 3
		script {close $client}
	} else {
		Debug "Received from client $client: $data" 3	
		
		if {$::commandqueue > 0 || $::isProcessing > 0 || $::clientcommandqueue > 0} {
			if {[llength $::clientcommandlist] > 10} {
				# send busy = 0002 to client
				Debug "Ignoring client command, commandlist exceeds 10" 1
				cAnswer $client 0002
			} else {			
				Debug "Queueing client command due to pending commands at [llength $::clientcommandlist]" 7
				lappend ::clientcommandlist [list $client $data]
				set ::clientcommandqueue [llength $::clientcommandlist]
			}
		} else {
			startProcessing $client $data
		}
	}
}

proc ProcessClientCommandList {} {
	if {[llength $::clientcommandlist] > 0} {
		if {[startProcessing [lindex [lindex $::clientcommandlist 0] 0] [lindex [lindex $::clientcommandlist 0] 1] ] >= 0 } {
			if {$::clientcommandqueue > 1} {
				set ::clientcommandlist [lrange $::clientcommandlist 1 [expr {$::clientcommandqueue-1}]]
			} else {
				Debug "Clearing clientqueue..." 7
				set ::clientcommandlist {}		
			}	
		}
	}
	set ::clientcommandqueue [llength $::clientcommandlist]
}

proc startProcessing {client data} {
	#queue processing
	if {$::isProcessing > 0 || $::commandqueue > 0} {
		return -1
		
	} else {
		if {[llength $::clientcommandlist] > 0} {
			Debug "Processing 1/[llength $::clientcommandlist] | $data " 7
		}
		
		set ::isProcessing 1
		
		if {[catch {pParse $client $data} msg]} {
			Debug "Unexpected Error during pParse $msg" 1
			script {close $client}
		}

		set ::isProcessing 0
		
		# rescheduling 
		if {$::commandqueue > 0} {
			Debug "Rescheduling queue processing from Client..." 7
			after idle [list after 0 ProcessCommandList]
			
		} elseif {$::clientcommandqueue > 0} {
			Debug "Rescheduling clientqueue processing from Client..." 7
			after idle [list after 0 ProcessClientCommandList]			
		}	

		return 0				
	}
}

proc cAnswer {client resultCode {data ""}} {
	if {$resultCode == 0 || $resultCode == 1} {
		set code \006
		set resultCode 0
	} else {
		set data ""
		set code \025
		Debug "Error response: $resultCode" 2		
	}
	
	if {$data != ""} {
		append data "$::sendDelimiter"
	}
	
	set result [join [list $code [string toupper [format %04x [expr {$resultCode & 0xffff}]]] $data] "$::sendDelimiter"]
	set rc [script { puts $client $result; flush $client }]
	if {$rc} {
		catch {close $client}
		Debug "Client \"$client\" removed due to socket error." 3
	} else {
		Debug "Sent to client $client: $result" 3
	}
}

proc cSendEventNotification {data} {
	foreach asyncClient $::asyncClients {
		if {$asyncClient != 0} {
			if {[expr 3 <= $::debugLevel]} {
				Debug "Send async to $asyncClient: $data" 3
			}
			
			set rc [script { puts $asyncClient $data; flush $asyncClient }]
			if {$rc} { 
				Debug "Async client \"$asyncClient\" removed from list due to socket error." 3
				set ::asyncClients [lremove $::asyncClients $asyncClient]
				catch { close $asyncClient }
			}
		}
	}
}

proc cSend {client data} {
	set rc [script { puts $client $data; flush $client }]
	if {$rc} {
		catch {close $client}
		Debug "Client \"$client\" removed due to socket error." 3
	} else {
		Debug "Sent to client $client: $data" 3
	}
}

# Events
proc ActualTemplateChanged {} {
	if {$::pushTemplateChange} {
		cSendEventNotification "[join {Event TemplateChanged} $::sendDelimiter]$::sendDelimiter"
	}
}

proc ActualStateChanged {newState} {
	if {$::pushStateChange} {
		fGetStatusCode stateCode
		cSendEventNotification "[join [list Event StatusChanged $newState $stateCode] $::sendDelimiter]$::sendDelimiter"
	}
	
	if {$newState == "LaserStatusMarking" && [llength $::varListSync] > 0} {
		for {set i 0} {$i < [llength $::varListSync]} {incr i} {
			
			set varName [lindex [lindex $::varListSync $i] 0]
			set varValue [lindex [lindex [lindex $::varListSync $i] 1] 0]
			
			set result [fSetVarValue $varName "" $varValue]
			
			if {[llength [lindex [lindex $::varListSync $i] 1]] > 1} {
				set ::varListSync [lreplace $::varListSync $i $i [list [lindex [lindex $::varListSync $i] 0] [lreplace [lindex [lindex $::varListSync $i] 1] 0 0]]]
			} else {
				set ::varListSync [lreplace $::varListSync $i $i]
				set i [expr $i-1]
			}
			
			cSendEventNotification "[join [list Event ValueSet $varName $varValue [string toupper [format %04x [expr {$result & 0xffff}]]]] $::sendDelimiter]$::sendDelimiter"
		}
	}
	
	if {$::pushMarkResult && $::previousState == "LaserStatusMarking" && $::markErrorOccured == 0} {
		cSendEventNotification "[join [list Event MarkResult Good] $::sendDelimiter]$::sendDelimiter"
	}
	
	if {$newState == "LaserStatusMarking"} {
		set ::markErrorOccured 0
	}
	
	set ::previousState $newState
}

proc ProductCounterValueChanged {} {
	if {$::pushProductCounterChange} {
		cSendEventNotification "[join [list Event ProductCounterChanged $::productCounter] $::sendDelimiter]$::sendDelimiter"
	}
}

proc MarkingCounterValueChanged {} {
	if {$::pushMarkingCounterChange} {
		cSendEventNotification "[join [list Event MarkingCounterChanged $::markingCounter] $::sendDelimiter]$::sendDelimiter"
	}
}

proc ErrorAppended {} {
	if {$::pushMarkResult && $::systemState == "LaserStatusMarking" && $::markErrorOccured == 0} {
		cSendEventNotification "[join [list Event MarkResult Bad] $::sendDelimiter]$::sendDelimiter"
		set ::markErrorOccured 1
	}
}

# Parsing

proc pParse {client data} {
	set resultdata ""
	
	# Replace receiveDelimiter by ACK
	set data [string map $::inputMapping $data]
	
	set result [ParseCustomizedProtocolExtension $client $data resultData]
	
	if {$result == -2} {
		if {[regexp "^\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter\(.*$::receiveDelimiter\)?" $data all command values] == 0} {
			Debug "Failed to Parse \"$data\"" 2
			set result $::dec_parseerror
			set resultdata ""
		} else {
			set command [string tolower $command]
			
			Debug "Parsing Command $command" 8
			Debug "Values $values" 8
			
			if {$result == -2} {
				set result [ParseStarter $command $values resultdata]
			}
			
			if {$result == -2} {
				set result [ParseExtension $command $values resultdata]
			}
			
			if {$result == -2} {
				set result [ParseUltimate $command $values resultdata]
			}
		}
		
		cAnswer $client $result $resultdata
	}
}

proc ParseUltimate {command values responseData} {
	upvar $responseData resultdata
	set result 0
	
	switch $command {
		start {
			set result [fStart]
		}
		stop {
			set result [fStop]
		}
		getstatus {
			set result [fGetStatus resultdata]
		}
		getstatuscode {
			set result [fGetStatusCode resultdata]
		}
		getvars {
			set result [fGetVars $values resultdata]
		}
		getvarnames {
			set result [fGetVarNames resultdata]
		}
		setvars {
			set result [fSetVars $values]
		}
		setvarssimple {
			set result [fSetVarsSimple $values Prompt]
		}
		getjobnames {
			set result [fGetJobNames resultdata]
		}
		getjob {
			set result [fGetJob resultdata]
		}
		setjob {
			set result [fSetJob $values]
		}
		setjobvars {
			set result [fSetJobVars $values]
		}
		setlayoutposition {
			set result [fSetLayoutPosition $values]
		}
		getlayoutposition {
			set result [fGetLayoutPosition resultdata]
		}
		setvarposition {
			set result [fSetVarPosition $values]
		}
		getvarposition {
			set result [fGetVarPosition $values resultdata]
		}
		setrotation {
			set result [fSetRotation $values]
		}
		getrotation {
			set result [fGetRotation resultdata]
		}
		getmessages {
			set result [fGetMessages resultdata]
		}
		getmessageid {
			set result [fGetMessageIDs resultdata]
		}
		confirmmessages {
			set result [fConfirmMessages]
		}
		deletemessages {
			set result [fDeleteMessages]
		}
		getrtc {
			set result [fGetRTC resultdata]
		}
		setrtc {
			set result [fSetRTC $values]
		}
		setrepeat {
			set result [fSetRepeat $values]
		}
		getrepeat {
			set result [fGetRepeat $values resultdata]
		}
		setrepeatsimple {
			set result [fSetRepeatSimple $values]
		}
		setincrementsimple {
			set result [fSetIncrementSimple $values]
		}
		setincrement {
			set result [fSetIncrement $values]
		}
		getincrement {
			set result [fGetIncrement $values resultdata]
		}
		setdateoffset {
			set result [fSetDateOffset $values]
		}
		getdateoffset {
			set result [fGetDateOffset $values resultdata]
		}
		setdateoffsetsimple {
			set result [fSetDateOffsetSimple $values]
		}
		setdateunit {
			set result [fSetDateUnit $values]
		}
		getdateunit {
			set result [fGetDateUnit $values resultdata]
		}
		setdateunitsimple {
			set result [fSetDateUnitSimple $values]
		}
		setstarttriggerdelay {
			set result [fSetTriggerDelay $values Start]
		}
		setstoptriggerdelay {
			set result [fSetTriggerDelay $values Stop]
		}
		setconsecutivetriggerdelay {
			set result [fSetTriggerDelay $values Consecutive]
		}
		getstarttriggerdelay {
			set result [fGetTriggerDelay resultdata Start]
		}
		getstoptriggerdelay {
			set result [fGetTriggerDelay resultdata Stop]
		}
		getconsecutivetriggerdelay {
			set result [fGetTriggerDelay resultdata Consecutive]
		}
		setintensity {
			set result [fSetIntensity $values]
		}
		getintensity {
			set result [fGetIntensity resultdata]
		}
		setmarkspeed {
			set result [fSetMarkSpeed $values]
		}
		getmarkspeed {
			set result [fGetMarkSpeed resultdata]
		}
		getglobalcounter {
			set result [fGetCounter "" resultdata]
		}
		getmarkingcounter {
			set result [fGetCounter "marking" resultdata]
		}
		resetmarkingcounter {
			set result [fResetCounter "marking"]
		}
		getproductcounter {
			set result [fGetCounter "product" resultdata]
		}
		resetproductcounter {
			set result [fResetCounter "product"]
		}
		setlotsize {
			set result [fSetLotSize $values]
		}
		getlotsize {
			set result [fGetLotSize resultdata]
		}
		getlotcounter {
			set result [fGetLotCounter resultdata]
		}
		setvarsasync {
			set result [fSetVarsAsync $values]
		}
		getuuid {
			set result [fGetUUID resultdata]
		}
		setemissionsource {
			set result [fSetEmissionSource $values]
		}
		getemissionsource {
			set result [fGetEmissionSource resultdata]
		}
		setfixedspeed {
			set result [fSetFixedSpeed $values]
		}
		getfixedspeed {
			set result [fGetFixedSpeed resultdata]
		}
		setmovementangle {
			set result [fSetMovementAngle $values]
		}
		getmovementangle {
			set result [fGetMovementAngle resultdata]
		}
		setproductregistration {
			set result [fSetProductRegistration $values]
		}
		getproductregistration {
			set result [fGetProductRegistration resultdata]
		}
		setparameterset {
			set result [fSetParameterSet $values]
		}
		getparameterset {
			set result [fGetParameterSet resultdata]
		}
		addbufferdata {
			set result [fAddBufferData $values]
		}
		clearbufferdata {
			set result [fClearBufferData $values]
		}
		getremainingbufferamount {
			set result [fGetRemainingBufferAmount $values resultdata]
		}
		resetserialnumber {
			set result [fResetSerialNumber $values]
		}
		setproductregistrationmode {
			set result [fSetProductRegistrationMode $values]
		}
		getproductregistrationmode {
			set result [fGetProductRegistrationMode resultdata]
		}
		setstarttriggermode {
			set result [fSetTriggerMode $values Start]
		}
		setconsecutivetriggermode {
			set result [fSetTriggerMode $values Consecutive]
		}
		setstoptriggermode {
			set result [fSetTriggerMode $values Stop]
		}
		getstarttriggermode {
			set result [fGetTriggerMode resultdata Start]
		}
		getconsecutivetriggermode {
			set result [fGetTriggerMode resultdata Consecutive]
		}
		getstoptriggermode {
			set result [fGetTriggerMode resultdata Stop]
		}
		getproductregistrationnames {
			set result [fGetProductRegistrationNames resultdata]
		}
		getparametersetnames {
			set result [fGetParameterSetNames resultdata]
		}
		gettemplatelistnames {
			set result [fGetTemplateListNames resultdata]
		}
		gettemplatesequencenames {
			set result [fGetTemplateSequenceNames resultdata]
		}
		gettemplatebatchnames {
			set result [fGetTemplateBatchNames resultdata]
		}
		setdatechange {
			set result [fSetDateChange $values]
		}
		getdatechange {
			set result [fGetDateChange $values resultdata]
		}
		setlayermarking {
			set result [fSetLayerMarking $values]
		}
		getlayermarking {
			set result [fGetLayerMarking $values resultdata]
		}
		runxmlcommand {
			set result [fRunXMLCommand $values resultdata]
		}
		default {
			set result $::dec_unknowncommand
		}
	}
	
	return $result
}

# Status

proc fGetStatus {laserStatus} {
	upvar $laserStatus state
	set state ""
	
	DebugStartTime
	Debug "In GetStatus" 8
	
	set state $::systemState
	
	DebugEndTime "GetStatus"
	
	return 0
}

proc fGetStatusCode {statusCode} {
	upvar $statusCode state
	set state -1
	
	DebugStartTime
	Debug "In GetStatusCode" 8
	
	set result [fGetStatus laserStatusText]
	
	switch $laserStatusText {
		LaserStatusPrepareForMarking {
			set state 1
		}
		LaserStatusMarking {
			set state 1
		}
		LaserStatusWaitForTrigger {
			set state 1
		}
		LaserStatusWaitForTriggerDelay {
			set state 1
		}
		LaserStatusPause {
			set state 1
		}
		LaserStatusWaitForPause {
			set state 1
		}
		LaserStatusReady {
			set state 0
		}
		LaserStatusStandby {
			set state 0
		}
		LaserStatusKeySwitchOpen {
			set state -1
		}		
		LaserStatusError1 {
			set state -1
		}
		LaserStatusError2 {
			set state -1
		}
		LaserStatusFatalError {
			set state -1
		}
		default {
			set state -1
		}
	}
	
	DebugEndTime "GetStatusCode"
	
	return $result
}

# Operation

proc fStart {} {
	set result 0
	DebugStartTime
	Debug "In Start" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode != 0} {
		set result $::dec_invalidstate
	} else {
		StackCommand $::dc_start
		set result [SendCommandStack response]
	}
	DebugEndTime "Start"
	
	return $result
}

proc fStop {} {
	set result 0
	DebugStartTime
	
	Debug "In Stop" 8
	
	set result [StopLaser]
	
	DebugEndTime "Stop"
	return $result
}

# Variables

proc fGetVars {varNames resultData {varType ""}} {
	upvar $resultData values
	set values ""
	
	DebugStartTime
	Debug "In GetVars" 8
	set varPath ""
	
	if {[string length $varNames] == 0} {
		set varPath "$::actualTemplatePath/Variables/Variable/attribute::Name|$::actualTemplatePath/Variables/Variable/*/Value"
	} else {
		while {[regexp "\(\[^$::receiveDelimiter\]+\)$::receiveDelimiter?\(.*\)" $varNames all varName varNames]} {
			if {[string length $varPath] > 0} {
				append varPath "|"
			}
			append varPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/attribute::Name|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/*/Value"
		}
	}
	
	set varPath [ConvertXPath $varPath]
	set varCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$varPath\"></Command>"
	StackCommand $varCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</\[^<\]*<Value>\(\[^<\]*\)</" $response]
		Debug "matches found = [expr {[llength $matches] / 2}]" 8
		
		foreach {all matchName matchValue} $matches {
			if {[string length $values] > 0 && [string length $matchName] > 0 && [string length $matchValue] > 0} {
				append values "$::sendDelimiter"
			}
			
			append values "$matchName=[string map $::outputMapping $matchValue]"
		}
	}
	
	DebugEndTime "GetVars"
	return $result
}

proc fGetVarType {varName varType} {
	upvar $varType type
	set type ""
	set result 0
	
	set varPath [ConvertXPath "name($::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/*)"]
	set varCommand "<Command Action=\"$::cmd_execxpath\" Location=\"$varPath\"></Command>"
	StackCommand $varCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp ">\\n(\[^<\]*)</" $response all type] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	return $result
}

proc fGetVarNames {varNames} {
	upvar $varNames names
	set names ""
	DebugStartTime
	Debug "In GetVarNames" 8
	
	set variablesPath "$::actualTemplatePath/Variables/Variable/attribute::Name"
	set varCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$variablesPath\"\>\n</Command>"
	
	StackCommand $varCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</" $response]
		
		Debug "matches found = [expr {[llength $matches] / 2}]" 8
		
		foreach {all match} $matches {
			if {[string length $names] > 0 && [string length $match] > 0} {
				append names "$::sendDelimiter"
			}
			
			append names $match
		}
	}
	DebugEndTime "GetVarNames"
	
	return $result
}

proc fSetVars {varData {varType ""}} {
	set result $::dec_parseerror
	
	DebugStartTime
	Debug "In SetVars" 8
	
	if {[regexp "\(?:.*$::receiveDelimiter\)\{0,1\}.+$::receiveDelimiter.*$::receiveDelimiter" $varData] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $varData" 2
	} else {
		#while {[regexp "\(.*$::receiveDelimiter\)\{0,1\}\(.+\)$::receiveDelimiter\(.*\)$::receiveDelimiter" $varData all varData varName varValue]} {}
		set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $varData]
		
		foreach {all varName varValue} $matches {
			set result [fSetVarValue $varName $varType $varValue 1]
		}
	}
	set result [SendCommandStack response]
	DebugEndTime "SetVars"
	
	return $result
}

proc fSetVarsSimple {varData {varType ""}} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetVarsSimple" 8
	
	set i 1

	while {[regexp "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter\(.*\)" $varData all varValue varData]} {
		
		set varName "Var$i"
		
		fSetVarValue $varName $varType $varValue 1
		
		incr i
	}
	
	if {[expr $i>1]} {
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetVarsSimple"
	
	return $result
}

proc fSetVarsAsync {varData {varType ""}} {
	set result 0
	
	DebugStartTime
	Debug "In SetVarsAsync" 8
	
	if {[regexp "\(?:.*$::receiveDelimiter\)\{0,1\}.+$::receiveDelimiter.*$::receiveDelimiter" $varData] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $varData" 2
	} else {
		set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $varData]
		
		foreach {all varName varValue} $matches {
			set foundInList 0
			for {set i 0} {$i<[llength $::varListSync]} {incr i} {
				if {[lindex [lindex $::varListSync $i] 0] == $varName} {
					set valuesList [lindex [lindex $::varListSync $i] 1]
					lappend valuesList $varValue
					set ::varListSync [lreplace $::varListSync $i $i [list $varName $valuesList]]
					set foundInList 1
				}
			}
			if {$foundInList == 0} {
				lappend ::varListSync [list $varName [list $varValue]]
			}
		}
	}
	
	DebugEndTime "SetVarsAsync"
	
	return $result
}

proc fSetVarValue {varName varType varValue {stack 0}} {
	set result 0
	Debug "In SetVarValue" 8
	
	if {$varType == "" || [lsearch $::rwVarTypes $varType] == -1} {
		set varType *
	}
	
	if {[string length $varValue] == 0} {
		set varValue " "
	}
	
	set varPath [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/$varType/Value"]
	set varCommand "<Command Action=\"$::cmd_modified\" Location=\"$varPath\">\n<Value>[string map $::sendMapping $varValue]</Value></Command>"
	
	StackCommand $varCommand
	
	if {$stack == 0} {
		set result [SendCommandStack response]
	}
	
	return $result
}

# Jobs

proc fGetJobNames {jobNames} {
	upvar $jobNames names
	set names ""
	DebugStartTime
	Debug "In GetJobNames" 8
	
	set templatesPath [ConvertXPath "$::dxp_templates/attribute::Name"]
	set templatesCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$templatesPath\"\>\n</Command>"
	StackCommand $templatesCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $names] > 0 && [string length $match] > 0} {
				append names "$::sendDelimiter"
			}
			
			append names $match
		}
	}
	
	DebugEndTime "GetJobNames"
	return $result
}

proc fGetJob {jobName} {
	upvar $jobName name
	set name ""
	
	DebugStartTime
	
	Debug "In GetJob" 8
	
	set prefix ""
	
	if {$::actualTemplateType == "TemplateList"} {
		set prefix "TL:"
	} elseif {$::actualTemplateType == "TemplateSequence"} {
		set prefix "TS:"
	} elseif {$::actualTemplateType == "TemplateBatch"} {
		set prefix "TB:"
	}
	
	set templatePath [ConvertXPath "$::actualTemplatePath/attribute::Name"]
	set templateCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$templatePath\"></Command>"
	StackCommand $templateCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $name] > 0 && [string length $match] > 0} {
				append name "$::sendDelimiter"
			}
			
			append name $match
		}
		set name $prefix$name
	}
	
	DebugEndTime "GetJob"
	
	return $result
}

proc fSetJob {jobName} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetJob" 8
	
	if {[regexp "(.+\)$::receiveDelimiter" $jobName all jobName]} {
		set templatePath [ConvertXPath "$::dxp_templates\[attribute::Name=\"$jobName\"\]/attribute::ID|$::dxp_templatelists\[attribute::Name=\"$jobName\"\]/attribute::ID|$::dxp_templatebatches\[attribute::Name=\"$jobName\"\]/attribute::ID|$::dxp_templatesequences\[attribute::Name=\"$jobName\"\]/attribute::ID"]
		set templateCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$templatePath\"></Command>"
		StackCommand $templateCommand
		set result [SendCommandStack response]
		
		if {$result == 0} {
			if {[regexp "<ID>\(\[^<\]*\)</" $response all id] != 1} {
				set result $::dec_parseerror
				Debug "Failed to Parse $response" 2
			} else {
				set ::ignoreTemplateChange 1
				set newTemplateCommand "<Command Action=\"$::cmd_modified\" Location=\"$::dxp_actualtemplate\">\n<ActualTemplate>$id</ActualTemplate>\n</Command>"
				StackCommand $newTemplateCommand
				set result [SendCommandStack response]
				
				if {$result == 0} {
					UpdateActualTemplateID $id
				}
				
				set ::ignoreTemplateChange 0
			}
		}
	}
	
	DebugEndTime "SetJob"
	
	return $result
}

proc fSetJobVars {values} {
	set result $::dec_parseerror
	
	Debug "In SetJobVars" 8
	
	if {[regexp "(\[^$::receiveDelimiter\]+$::receiveDelimiter\)\(.*\)" $values all jobName varData]} {
		set result [fSetJob $jobName]
		
		if {$result == 0} {
			set result [fSetVars $varData]
		}
	}
	
	return $result
}

# TemplateAdjustment

proc fSetLayoutPosition {values} {
	set result $::dec_parseerror
	
	DebugStartTime
	Debug "In SetLayoutPosition" 8
	
	if {[regexp "(\[\\+\\-0-9\]+?)$::receiveDelimiter\(\[\\+\\-0-9\]+?\)$::receiveDelimiter.*" $values all x y]} {
	
		set pathX [ConvertXPath "$::actualTemplatePath/TemplateAdjust/AdjustOffsetX"]
		set commandX "<Command Action=\"$::cmd_modified\" Location=\"$pathX\"><AdjustOffsetX>$x</AdjustOffsetX></Command>"
		
		set pathY [ConvertXPath "$::actualTemplatePath/TemplateAdjust/AdjustOffsetY"]
		set commandY "<Command Action=\"$::cmd_modified\" Location=\"$pathY\"><AdjustOffsetY>$y</AdjustOffsetY></Command>"
		
		StackCommand $commandX
		StackCommand $commandY
	
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetLayoutPosition"
	return $result
}

proc fGetLayoutPosition {xy} {
	upvar $xy resultdata
	set result 0
	DebugStartTime
	
	Debug "In GetLayoutPosition" 8
	
	set pathX [ConvertXPath "$::actualTemplatePath/TemplateAdjust/AdjustOffsetX|$::actualTemplatePath/TemplateAdjust/AdjustOffsetY"]
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$pathX\"></Command>"
	
	StackCommand $command
	set result [SendCommandStack response]
	
	if {[regexp "<AdjustOffsetX>\(\[^<\]*\)</" $response all x] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $response" 8
	}
	if {[regexp "<AdjustOffsetY>\(\[^<\]*\)</" $response all y] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $response" 8
	}
	
	if {$result == 0} {
		set resultdata $x$::sendDelimiter$y
	}
	
	DebugEndTime "GetLayoutPosition"
	
	return $result
}

proc fSetRotation {values} {
	set result 0
	DebugStartTime
	Debug "In SetRotation" 8
	
	if {[regexp "((\[\\+\\-0-9\]+\.?\[0-9\]*))$::receiveDelimiter.*" $values all rotation]} {
		set path [ConvertXPath "$::actualTemplatePath/TemplateAdjust/AdjustRotation"]
		set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><AdjustRotation>$rotation</AdjustRotation></Command>"
		
		StackCommand $command
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetRotation"
	
	return $result
}

proc fGetRotation {rotation} {
	upvar $rotation rot
	set result 0
	DebugStartTime
	Debug "In GetRotation" 8
	
	set path [ConvertXPath "$::actualTemplatePath/TemplateAdjust/AdjustRotation"]
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
	
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<AdjustRotation>\(\[^<\]*\)</" $response all rot] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
		
	DebugEndTime "GetRotation"
	
	return $result
}

# Messages

proc fGetMessages {messages} {
	upvar $messages resultdata
	set result 0
	
	DebugStartTime
	Debug "In GetMessages" 8
	
	StackCommand $::dc_getmessagetextsnak
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<MessageText>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $resultdata] > 0 && [string length $match] > 0} {
				append resultdata "$::sendDelimiter"
			}
			
			append resultdata $match
		}
	} elseif {$result == 45023} {
		set result 0
	}
	
	DebugEndTime "GetMessages"
	
	return $result
}

proc fGetMessageIDs {messageIDs} {
	upvar $messageIDs resultdata
	set result 0
	
	DebugStartTime
	Debug "In GetMessageIDs" 8
	
	StackCommand $::dc_getmessageidsnak
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<ErrorCode>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $resultdata] > 0 && [string length $match] > 0} {
				append resultdata "$::sendDelimiter"
			}
			
			append resultdata $match
		}
	} elseif {$result == 45023} {
		set result 0
	}
	
	DebugEndTime "GetMessageIDs"
	
	return $result
}

proc fConfirmMessages {} {
	set result 0
	DebugStartTime
	Debug "In ConfirmMessages" 8
	
	StackCommand $::dc_confirmmessages
	set result [SendCommandStack response]
	
	DebugEndTime "ConfirmMessages"
	return $result
}

proc fDeleteMessages {} {
	set result 0
	DebugStartTime
	Debug "In DeleteMessages" 8
	
	StackCommand $::dc_deletemessages
	set result [SendCommandStack response]
	
	DebugEndTime "DeleteMessages"
	return $result
}

# System

proc fGetRTC {rtc} {
	upvar $rtc value
	set result 0
	DebugStartTime
	Debug "In GetRTC" 8
	
	StackCommand $::dc_getrtc
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<Clock>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetRTC"
	
	return $result
}

proc fSetRTC {values} {
	set result 0
	DebugStartTime
	Debug "In SetRTC" 8
	
	if {[regexp {([0-9]{4}-[0-9]{1,2}-[0-9]{1,2}T[0-2]{1}[0-9]{1}:[0-6]{1}[0-9]{1}:[0-6]{1}[0-9]{1}).*} $values all values] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $values" 2
	}
	
	if {$result == 0} {
		set command "<Command Action=\"$::cmd_modified\" Location=\"$::dxp_clock\"><Clock>$values</Clock></Command>"
		StackCommand $command
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetRTC"
	
	return $result
}

# TemplateContent

proc fSetVarPosition {values} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetVarPosition" 8
	
	while {[regexp "\(\[^$::receiveDelimiter\]+\)$::receiveDelimiter\(\[+-\]?\[0-9\]+\.?\[0-9\]*\)$::receiveDelimiter\(\[+-\]?\[0-9\]+\.?\[0-9\]*\)$::receiveDelimiter\(.*\)" $values all varname x y values]} {
		set pathX "$::actualTemplatePath/GraphObjectPool/GraphObject\[TextField/TextFieldText/TextLine/TextFragment/Token/VariableID/text\(\)=$::actualTemplatePath/Variables/Variable\[attribute::Name=&quot;$varname&quot;\]/attribute::ID\]/TransMatrix/tx"
		set pathY "$::actualTemplatePath/GraphObjectPool/GraphObject\[TextField/TextFieldText/TextLine/TextFragment/Token/VariableID/text\(\)=$::actualTemplatePath/Variables/Variable\[attribute::Name=&quot;$varname&quot;\]/attribute::ID\]/TransMatrix/ty"
		set commandX "<Command Action=\"$::cmd_modified\" Location=\"$pathX\"><tx>[format %.5f [expr {$x*10000}]]</tx></Command>"
		set commandY "<Command Action=\"$::cmd_modified\" Location=\"$pathY\"><ty>[format %.5f [expr {$y*10000}]]</ty></Command>"
		StackCommand $commandX
		StackCommand $commandY
		set result 0
	}
	
	if {$result == 0} {
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetVarPosition"
	
	return $result
}

proc fGetVarPosition {varNames resultData} {
	upvar $resultData values
	set values ""
	
	set result $::dec_parseerror
	DebugStartTime
	Debug "In GetVarPosition" 8
	
	set varPath ""
	
	while {[regexp "\(\[^$::receiveDelimiter\]+\)$::receiveDelimiter?\(.*\)" $varNames all varName varNames]} {
		
		set pathX "$::actualTemplatePath/GraphObjectPool/GraphObject\[TextField/TextFieldText/TextLine/TextFragment/Token/VariableID/text\(\)=$::actualTemplatePath/Variables/Variable\[attribute::Name=&quot;$varName&quot;\]/attribute::ID\]/TransMatrix/tx"
		set pathY "$::actualTemplatePath/GraphObjectPool/GraphObject\[TextField/TextFieldText/TextLine/TextFragment/Token/VariableID/text\(\)=$::actualTemplatePath/Variables/Variable\[attribute::Name=&quot;$varName&quot;\]/attribute::ID\]/TransMatrix/ty"
		
		set varPath $pathX
		append varPath "|"
		append varPath $pathY
		
		set varPath [ConvertXPath $varPath]
		set varCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$varPath\"></Command>"
		StackCommand $varCommand
		set result [SendCommandStack response]
		
		if {$result == 0} {
			if {[regexp "<tx>\(\[^<\]*\)</\[^<\]*<ty>\(\[^<\]*\)</" $response all x y]} {
				if {[string length $values] > 0 && [string length $x] > 0 && [string length $y] > 0} {
					append values "$::sendDelimiter"
				}
				
				append values "$varName$::sendDelimiter[format %.5f [expr {$x/10000}]]$::sendDelimiter[format %.5f [expr {$y/10000}]]"
			}
		}
	}
	
	DebugEndTime "GetVarPosition"
	return $result
}

proc fSetRepeat {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetRepeat" 8
	
	if {[regexp "\(?:.*$::receiveDelimiter\)\{0,1\}.+$::receiveDelimiter.*$::receiveDelimiter" $varData] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $varData" 2
	} else {
		while {[regexp "\(.*$::receiveDelimiter\)\{0,1\}\(.+\)$::receiveDelimiter\(\[0-9\]+\)$::receiveDelimiter" $varData all varData varName value]} {
			set result [fSetRepeatValue $varName $value 0]
			
			if {$result != 0} {
				break
			}
		}
	}
	
	DebugEndTime "SetRepeat"
	
	return $result
}

proc fGetRepeat {values  resultData} {
	upvar $resultData resultValues
	set resultValues ""
	
	set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values]
	set path ""
	
	foreach {all varName} $matches {
		if {[string length $path] > 0} {
			append path "|"
		}
		append path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/attribute::Name|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/*/Repeat"]
	}
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</\[^<\]*<Repeat>\(\[^<\]*\)</" $response]
		
		foreach {all varName repeat} $matches {
			if {[string length $resultValues] > 0} {
				append resultValues "$::sendDelimiter"
			}
			
			append resultValues $varName$::sendDelimiter$repeat
		}
	}
	
	return $result
}

proc fSetRepeatSimple {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetRepeatSimple" 8
	
	set i 1

	while {[regexp "^\(\[0-9\]+\)$::receiveDelimiter\(.*\)" $varData all value varData]} {
		
		set varName "Ser$i"
		
		fSetRepeatValue $varName $value 1
		
		incr i
	}
	
	if {[expr $i > 1]} {
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetRepeatSimple"
	
	return $result
}

proc fSetRepeatValue {varName value {stack 0}} {
	set result 0
	Debug "In SetRepeatValue" 8
	
	set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/SerialNumber/Repeat"]
	set command "<Command Action=\"$::cmd_modified\" Location=\"$path\">\n<Repeat>$value</Repeat>\n</Command>"
	
	StackCommand $command
	
	if {$stack == 0} {
		set result [SendCommandStack response]
	}
	
	return $result
}

proc fSetIncrement {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetIncrement" 8
	
	if {[regexp "\(?:.*$::receiveDelimiter\)\{0,1\}.+$::receiveDelimiter.*$::receiveDelimiter" $varData] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $varData" 2
	} else {
		while {[regexp "\(.*$::receiveDelimiter\)\{0,1\}\(.+\)$::receiveDelimiter\(\[0-9\]+\)$::receiveDelimiter" $varData all varData varName value]} {
			set result [fSetIncrementValue $varName $value 0]
			
			if {$result != 0} {
				break
			}
		}
	}
	
	DebugEndTime "SetIncrement"
	
	return $result
}

proc fGetIncrement {values  resultData} {
	upvar $resultData resultValues
	set resultValues ""
	
	set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values]
	set path ""
	
	foreach {all varName} $matches {
		if {[string length $path] > 0} {
			append path "|"
		}
		append path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/attribute::Name|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/*/Increment"]
	}
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</\[^<\]*<Increment>\(\[^<\]*\)</" $response]
		
		foreach {all varName increment} $matches {
			if {[string length $resultValues] > 0} {
				append resultValues "$::sendDelimiter"
			}
			
			append resultValues $varName$::sendDelimiter$increment
		}
	}
	
	return $result
}

proc fSetIncrementSimple {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetIncrementSimple" 8
	
	set i 1

	while {[regexp "^\(\[0-9\]+\)$::receiveDelimiter\(.*\)" $varData all value varData]} {
		
		set varName "Ser$i"
		
		fSetIncrementValue $varName $value 1
		
		incr i
	}
	
	if {[expr $i > 1]} {
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetIncrementSimple"
	
	return $result
}

proc fSetIncrementValue {varName value {stack 0}} {
	set result 0
	Debug "In SetIncrementValue" 8
	
	set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/SerialNumber/Increment"]
	set command "<Command Action=\"$::cmd_modified\" Location=\"$path\">\n<Increment>$value</Increment>\n</Command>"
	
	StackCommand $command
	
	if {$stack == 0} {
		set result [SendCommandStack response]
	}
	
	return $result
}

proc fSetDateOffset {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetDateOffset" 8
	
	if {[regexp "\(?:.*$::receiveDelimiter\)\{0,1\}.+$::receiveDelimiter.*$::receiveDelimiter" $varData] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $varData" 2
	} else {
		while {[regexp "\(.*$::receiveDelimiter\)\{0,1\}\(.+\)$::receiveDelimiter\(\[0-9\]+\)$::receiveDelimiter" $varData all varData varName value]} {
			set result [fSetDateOffsetValue $varName $value 0]
			
			if {$result != 0} {
				break
			}
		}
	}
	
	DebugEndTime "SetDateOffset"
	
	return $result
}

proc fGetDateOffset {values  resultData} {
	upvar $resultData resultValues
	set resultValues ""
	
	set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values]
	set path ""
	
	foreach {all varName} $matches {
		if {[string length $path] > 0} {
			append path "|"
		}
		append path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/attribute::Name|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/*/DateOffset/DateOffsetValue"]
	}
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</\[^<\]*<DateOffsetValue>\(\[^<\]*\)</" $response]
		
		foreach {all varName dateOffset} $matches {
			if {[string length $resultValues] > 0} {
				append resultValues "$::sendDelimiter"
			}
			
			append resultValues $varName$::sendDelimiter$dateOffset
		}
	}
	
	return $result
}

proc fSetDateOffsetSimple {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetDateOffsetSimple" 8
	
	set i 1

	while {[regexp "^\(\[0-9\]+\)$::receiveDelimiter\(.*\)" $varData all value varData]} {
		
		set varName "Date$i"
		
		fSetDateOffsetValue $varName $value 1
		
		incr i
	}
	
	if {[expr $i > 1]} {
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetDateOffsetSimple"
	
	return $result
}

proc fSetDateOffsetValue {varName value {stack 0}} {
	set result 0
	Debug "In SetDateOffsetValue" 8
	
	set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/Date/DateOffset/DateOffsetValue"]
	set command "<Command Action=\"$::cmd_modified\" Location=\"$path\">\n<DateOffsetValue>$value</DateOffsetValue>\n</Command>"
	
	StackCommand $command
	
	if {$stack == 0} {
		set result [SendCommandStack response]
	}
	
	return $result
}

proc fSetDateUnit {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetDateUnit" 8
	
	if {[regexp "\(?:.*$::receiveDelimiter\)\{0,1\}.+$::receiveDelimiter.*$::receiveDelimiter" $varData] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $varData" 2
	} else {
		while {[regexp "\(.*$::receiveDelimiter\)\{0,1\}\(.+\)$::receiveDelimiter\(Days|Weeks|Months|Years\){1}$::receiveDelimiter" $varData all varData varName value]} {
			set result [fSetDateUnitValue $varName $value 0]
			
			if {$result != 0} {
				break
			}
		}
	}
	
	DebugEndTime "SetDateUnit"
	
	return $result
}

proc fGetDateUnit {values  resultData} {
	upvar $resultData resultValues
	set resultValues ""
	
	set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values]
	set path ""
	
	foreach {all varName} $matches {
		if {[string length $path] > 0} {
			append path "|"
		}
		append path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/attribute::Name|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/*/DateOffset/DateOffsetUnit"]
	}
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</\[^<\]*<DateOffsetUnit>\(\[^<\]*\)</" $response]
		
		foreach {all varName dateUnit} $matches {
			if {[string length $resultValues] > 0} {
				append resultValues "$::sendDelimiter"
			}
			
			append resultValues $varName$::sendDelimiter$dateUnit
		}
	}
	
	return $result
}

proc fSetDateUnitSimple {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetDateUnitSimple" 8
	
	set i 1

	while {[regexp "\(Days|Weeks|Months|Years\){1}$::receiveDelimiter\(.*\)" $varData all value varData]} {
		
		set varName "Date$i"
		
		fSetDateUnitValue $varName $value 1
		
		incr i
	}
	
	if {[expr $i > 1]} {
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetDateUnitSimple"
	
	return $result
}

proc fSetDateUnitValue {varName value {stack 0}} {
	set result 0
	Debug "In SetDateUnitValue" 8
	
	set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/Date/DateOffset/DateOffsetUnit"]
	set command "<Command Action=\"$::cmd_modified\" Location=\"$path\">\n<DateOffsetUnit>$value</DateOffsetUnit>\n</Command>"
	
	StackCommand $command
	
	if {$stack == 0} {
		set result [SendCommandStack response]
	}
	
	return $result
}

# ProductRegistration

proc fSetTriggerDelay {values type} {
	set result 0
	DebugStartTime
	Debug "In SetTriggerDelay" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		if {[regexp "(\[0-9\]+)$::receiveDelimiter" $values all values]} {
			switch $type {
				Start {
					set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/StartTrigger/StartDelay"]
					set node "StartDelay"
				}
				Stop {
					set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/StopTrigger/StopDelay"]
					set node "StopDelay"
				}
				Consecutive {
					set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/ConsecutiveTrigger/ConsecutiveDelay"]
					set node "ConsecutiveDelay"
				}
				default {
					set result -1
					Debug "Failed to Parse $type" 2
				}
			}
			
			if {$result == 0} {
				set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><$node>$values</$node></Command>"
				StackCommand $command
				set result [SendCommandStack response]
			}
		} else {
			set result $::dec_parseerror
			Debug "Failed to Parse $values" 2
		}
	}
	
	DebugEndTime "SetTriggerDelay"
	
	return $result
}

proc fGetTriggerDelay {delay type} {
	upvar $delay resultdata
	set resultdata ""
	set result 0
	DebugStartTime
	Debug "In GetTriggerDelay" 8
	
	switch $type {
		Start {
			set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/StartTrigger/StartDelay"]
			set node "StartDelay"
		}
		Stop {
			set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/StopTrigger/StopDelay"]
			set node "StopDelay"
		}
		Consecutive {
			set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/ConsecutiveTrigger/ConsecutiveDelay"]
			set node "ConsecutiveDelay"
		}
		default {
			set result $::dec_unknowncommand
			Debug "Unknown Type $type" 2
		}
	}
	
	if {$result == 0} {
		set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
		StackCommand $command
		set result [SendCommandStack response]
	}
	
	if {$result == 0} {
		if {[regexp "<$node\[^>\]*>\(\[^<\]*\)</" $response all resultdata] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetTriggerDelay"
	
	return $result
}

# Parameter

proc fSetIntensity {power} {

	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetIntensity" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		set i 1
		while {[regexp "^((?:^0?|^\[1-9\]\[0-9\]?)(?:\\.\[0-9\]*)?|^100(?:\\.0*)?)$::receiveDelimiter\(.*\)" $power all val power]} {
			set path [ConvertXPath "$::dxp_parametersets\[attribute::ID=\"$::parametersetID\"\]/Indices/Index\[attribute::Name=\"Index$i\"\]/MarkingIntensity"]
			set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><MarkingIntensity>[expr $val]</MarkingIntensity></Command>"
			
			StackCommand $command
			set result [SendCommandStack response]
			
			if {$result != 0} {
				break
			}
			
			incr i
		}
	}
	
	DebugEndTime "SetIntensity"
	
	return $result
}

proc fGetIntensity {power} {
	upvar $power resultdata
	set resultdata ""
	set result 0
	DebugStartTime
	Debug "In GetIntensity" 8
	
	set i 1
	while {1} {
		set path [ConvertXPath "$::dxp_parametersets\[attribute::ID=\"$::parametersetID\"\]/Indices/Index\[attribute::Name=\"Index$i\"\]/MarkingIntensity"]
		set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
		
		StackCommand $command
		set result [SendCommandStack response]
		
		if {$result == 0} {
			if {[regexp "<MarkingIntensity>\(\[^<\]*\)</" $response all intensity] == 1} {
				if {[string length $resultdata] != 0} {
					append resultdata $::sendDelimiter
				}
				
				append resultdata $intensity
			}
		} else {
			set result 0
			break
		}
		
		incr i
	}
	
	DebugEndTime "GetIntensity"
	
	return $result
}

proc fSetMarkSpeed {markspeed} {

	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetMarkSpeed" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		set i 1
		while {[regexp "\(\[0-9\]+\)$::receiveDelimiter\(.*\)" $markspeed all val markspeed]} {
			set path [ConvertXPath "$::dxp_parametersets\[attribute::ID=\"$::parametersetID\"\]/Indices/Index\[attribute::Name=\"Index$i\"\]/vMark"]
			set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><vMark>$val</vMark></Command>"
			
			StackCommand $command
			
			incr i
		}
		
		Debug "i=$i" 8
		Debug "CommandStack = $::cmd_Stack" 8
		
		if {[expr $i>1]} {
			set result [SendCommandStack response]
		}
	}
	
	DebugEndTime "SetMarkSpeed"
	
	return $result
}

proc fGetMarkSpeed {markspeed} {
	upvar $markspeed resultdata
	set resultdata ""
	set result 0
	DebugStartTime
	Debug "In GetMarkSpeed" 8
	
	set i 1
	while {1} {
		set path [ConvertXPath "$::dxp_parametersets\[attribute::ID=\"$::parametersetID\"\]/Indices/Index\[attribute::Name=\"Index$i\"\]/vMark"]
		set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
		
		StackCommand $command
		set result [SendCommandStack response]
		
		if {$result == 0} {
			if {[regexp "<vMark>\(\[^<\]*\)</" $response all vMark] == 1} {
				if {[string length $resultdata] != 0} {
					append resultdata $::sendDelimiter
				}
				
				append resultdata $vMark
			}
		} else {
			set result 0
			break
		}
		
		incr i
	}
	
	DebugEndTime "GetMarkSpeed"
	
	return $result
}

proc fGetCounter {type countervalue} {
	upvar $countervalue value
	set value ""
	set result 0
	DebugStartTime
	
	set path $::dxp_globalmarkingcounter
	set pattern "<GlobalPrintCounter>\(\[^<\]*\)</"
	switch $type {
		marking {
			set path $::dxp_markingcounter
			set pattern "<PrintCounterValue>\(\[^<\]*\)</"
		}
		product {
			set path $::dxp_productcounter
			set pattern "<ProductCounterValue>\(\[^<\]*\)</"
		}
	}
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
	
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "$pattern" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetCounter"
	return $result
}

proc fResetCounter {type} {
	set result 0
	DebugStartTime
	
	set path $::dxp_markingcounter
	set pattern1 "<PrintCounterValue>"
	set pattern2 "</PrintCounterValue>"
	switch $type {
		product {
			set path $::dxp_productcounter
			set pattern1 "<ProductCounterValue>"
			set pattern2 "</ProductCounterValue>"
		}
	}
	
	set command "<Command Action=\"$::cmd_modified\" Location=\"$path\">"
	append command $pattern1
	append command "0"
	append command $pattern2
	append command "</Command>"
	
	StackCommand $command
	set result [SendCommandStack response]
	
	DebugEndTime "ResetCounter"
	return $result
}

proc fSetLotSize {values} {
	
	set result $::dec_parseerror
	DebugStartTime
	
	if {[regexp "\(\[0-9\]+\)$::receiveDelimiter.*" $values all lotsize]} {
		
		set command "<Command Action=\"$::cmd_modified\" Location=\"$::dxp_lotsize\"><LotSize>$lotsize</LotSize></Command>"
		StackCommand $command
		set command "<Command Action=\"$::cmd_modified\" Location=\"$::dxp_lotcounter\"><LotCounterValue>0</LotCounterValue></Command>"
		StackCommand $command
		set result [SendCommandStack response]
	}
	
	DebugEndTime "SetLotSize"
	return $result
}

proc fGetLotSize {sizeValue} {
	upvar $sizeValue value
	set value ""
	set result 0
	DebugStartTime
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$::dxp_lotsize\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<LotSize>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetLotSize"
	return $result
}

proc fGetLotCounter {lotValue} {
	upvar $lotValue value
	set value ""
	set result 0
	DebugStartTime
	
	StackCommand $::dc_getlotcounter
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<LotCounterValue>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetCounter"
	return $result
}

proc fGetUUID {uuidValue} {
	upvar $uuidValue value
	set value ""
	set result 0
	DebugStartTime
	set value [GenerateUniqueID]
	DebugEndTime "GetUUID"
	return $result
}

proc fSetEmissionSource {values} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetEmissionSource" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		if {[regexp "^\(BOTH_LASER|PILOT_LASER|MARKING_LASER\){1}$::receiveDelimiter" $values all value]} {
			set path [ConvertXPath "/Root/Lasers/Laser/Operation/EmissionSource"]
			set command "<Command Action=\"$::cmd_modified\" Location=\"$path\">\n<EmissionSource>$value</EmissionSource>\n</Command>"
			
			StackCommand $command
			set ::ignoreTemplateChange 1
			set result [SendCommandStack response]
			set ::ignoreTemplateChange 0
		}
	}
	
	DebugEndTime "SetEmissionSource"
	return $result
}

proc fGetEmissionSource {sourceValue} {
	upvar $sourceValue value
	set value ""
	set result 0
	DebugStartTime
	Debug "In GetEmissionSource" 8
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"[ConvertXPath /Root/Lasers/Laser/Operation/EmissionSource]\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<EmissionSource>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetEmissionSource"
	return $result
}

proc fSetFixedSpeed {values} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetFixedSpeed" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		if {[regexp "^\(\[+-\]?\[0-9\]+\.?\[0-9\]*\)$::receiveDelimiter" $values all speed]} {
			if {[expr $speed > 0]} {
				set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/MOTF_Configuration/FixedSpeed"]
				set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><FixedSpeed>$speed</FixedSpeed></Command>"
				
				StackCommand $command
				set result [SendCommandStack response]
			}
		}
	}
	
	DebugEndTime "SetFixedSpeed"
	return $result
}

proc fGetFixedSpeed {speedValue} {
	upvar $speedValue value
	set value 0
	set result 0
	DebugStartTime
	Debug "In GetFixedSpeed" 8
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"[ConvertXPath $::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/MOTF_Configuration/FixedSpeed]\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<FixedSpeed>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetFixedSpeed"
	return $result
}

proc fSetMovementAngle {values} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetMovementAngle" 8
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		if {[regexp "^\(\[+-\]?\[0-9\]+\.?\[0-9\]*\)$::receiveDelimiter" $values all angle]} {
			if {[expr $angle>=-360] && [expr $angle<=360]} {
				set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/MOTF_Configuration/Angle"]
				set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><Angle>$angle</Angle></Command>"
				StackCommand $command
				set result [SendCommandStack response]
			}
		}
	}
	
	DebugEndTime "SetMovementAngle"
	return $result
}

proc fGetMovementAngle {movementValue} {
	upvar $movementValue value
	set value 0
	set result 0
	DebugStartTime
	Debug "In GetMovementAngle" 8
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"[ConvertXPath $::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/MOTF_Configuration/Angle]\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<Angle>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetMovementAngle"
	return $result
}

proc fSetProductRegistration {values} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetProductRegistration" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		if {[regexp "^\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values all configuration]} {
			set path [ConvertXPath "$::dxp_configurations\[attribute::Name=\"$configuration\"\]/attribute::ID"]
			set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
			
			StackCommand $command
			set result [SendCommandStack response]
			
			if {$result == 0 && [regexp "<ID>\(\[^<\]*\)</" $response all configurationId] != 1} {
				set result $::dec_parseerror
				Debug "Failed to Parse $response" 2
			}
			
			if {$result == 0} {
				set path [ConvertXPath "$::actualTemplatePath/ConfigurationID"]
				set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><ConfigurationID>$configurationId</ConfigurationID></Command>"
				
				StackCommand $command
				set result [SendCommandStack response]
			}
			
			if {$result == 0} {
				set ::configurationID $configurationId
			}
		}
	}
	
	DebugEndTime "SetProductRegistration"
	return $result
}

proc fGetProductRegistration {productRegistrationValue} {
	upvar $productRegistrationValue value
	set value 0
	set result 0
	DebugStartTime
	Debug "In GetProductRegistration" 8
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"[ConvertXPath $::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/attribute::Name]\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<Name>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetProductRegistration"
	return $result
}

proc fSetParameterSet {values} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetParameterSet" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		if {[regexp "^\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values all parameterSet]} {
			set path [ConvertXPath "$::dxp_parametersets\[attribute::Name=\"$parameterSet\"\]/attribute::ID"]
			set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
			
			StackCommand $command
			set result [SendCommandStack response]
			
			if {$result == 0 && [regexp "<ID>\(\[^<\]*\)</" $response all parameterSetId] != 1} {
				set result $::dec_parseerror
				Debug "Failed to Parse $response" 2
			}
			
			if {$result == 0} {
				set path [ConvertXPath "$::actualTemplatePath/ParameterSetID"]
				set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><ParameterSetID>$parameterSetId</ParameterSetID></Command>"
				
				StackCommand $command
				set result [SendCommandStack response]
			}
			
			if {$result == 0} {
				set ::parametersetID $parameterSetId
			}
		}
	}
	
	DebugEndTime "SetProductRegistration"
	return $result
}

proc fGetParameterSet {parameterSetValue} {
	upvar $parameterSetValue value
	set value 0
	set result 0
	DebugStartTime
	Debug "In GetParameterSet" 8
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"[ConvertXPath $::dxp_parametersets\[attribute::ID=\"$::parametersetID\"\]/attribute::Name]\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<Name>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetParameterSet"
	return $result
}

proc fResetSerialNumber {values} {
	set result $::dec_parseerror
	
	DebugStartTime
	Debug "In ResetSerialNumber" 8
	
	set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values]
	set path ""
	
	foreach {all varName} $matches {
		if {[string length $path] > 0} {
			append path "|"
		}
		append path "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/attribute::Name|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/*/StartValue"
	}
	
	if {[string length $path] > 0} {
		set command "<Command Action=\"$::cmd_getsubtree\" Location=\"[ConvertXPath $path]\"></Command>"
		StackCommand $command
		set result [SendCommandStack response]
	}
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</\[^<\]*<StartValue>\(\[^<\]*\)</" $response]
		
		foreach {all matchName matchValue} $matches {
			set path "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$matchName\"\]/*/Value"
			set command "<Command Action=\"$::cmd_modified\" Location=\"[ConvertXPath $path]\"><Value>$matchValue</Value></Command>"
			StackCommand $command
		}
		
		set result [SendCommandStack response]
	}
	
	DebugEndTime "ResetSerialNumber"
	
	return $result
}

proc fSetProductRegistrationMode {values} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetProductRegistrationMode" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		if {[regexp "^\(None|FixedSpeed|Encoder\){1}$::receiveDelimiter" $values all value]} {
			set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/MOTF_Configuration/Type"]
			set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><Type>$value</Type></Command>"
			
			StackCommand $command
			set ::ignoreTemplateChange 1
			set result [SendCommandStack response]
			set ::ignoreTemplateChange 0
		}
	}
	
	DebugEndTime "SetProductRegistrationMode"
	return $result
}

proc fGetProductRegistrationMode {motfModeValue} {
	upvar $motfModeValue value
	set value 0
	set result 0
	DebugStartTime
	Debug "In GetProductRegistrationMode" 8
	
	set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/MOTF_Configuration/Type"]
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		if {[regexp "<Type>\(\[^<\]*\)</" $response all value] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetProductRegistrationMode"
	return $result
}

proc fSetTriggerMode {values type} {
	set result 0
	DebugStartTime
	Debug "In SetTriggerMode" 8
	
	fGetStatusCode statusCode
	
	if {$statusCode == 1} {
		set result $::dec_invalidstate
	} else {
		if {[regexp "^\(none|trigger1fall|trigger1raise|auto|program\){1}$::receiveDelimiter" $values all value]} {
			switch $type {
				Start {
					if {$value == "none"} {
						set result $::dec_parameterinvalid
					}
					set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/StartTrigger/TriggerSource"]
				}
				Stop {
					if {$value == "auto" || $value == "program"} {
						set result $::dec_parameterinvalid
					}
					set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/StopTrigger/TriggerSource"]
				}
				Consecutive {
					set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/ConsecutiveTrigger/TriggerSource"]
				}
				default {
					set result $::dec_parseerror
					Debug "Failed to Parse $type" 2
				}
			}
			
			if {$result == 0} {
				set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><TriggerSource>$value</TriggerSource></Command>"
				StackCommand $command
				set result [SendCommandStack response]
			}
		} else {
			set result $::dec_parseerror
			Debug "Failed to Parse $values" 2
		}
	}
	
	DebugEndTime "SetTriggerMode"
	
	return $result
}

proc fGetTriggerMode {triggerMode type} {
	upvar $triggerMode resultdata
	set resultdata ""
	set result 0
	DebugStartTime
	Debug "In GetTriggerMode" 8
	
	switch $type {
		Start {
			set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/StartTrigger/TriggerSource"]
		}
		Stop {
			set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/StopTrigger/TriggerSource"]
		}
		Consecutive {
			set path [ConvertXPath "$::dxp_configurations\[attribute::ID=\"$::configurationID\"\]/ConsecutiveTrigger/TriggerSource"]
		}
		default {
			set result $::dec_parseerror
			Debug "Unknown Type $type" 2
		}
	}
	
	if {$result == 0} {
		set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
		StackCommand $command
		set result [SendCommandStack response]
	}
	
	if {$result == 0} {
		if {[regexp "<TriggerSource\[^>\]*>\(\[^<\]*\)</" $response all resultdata] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		}
	}
	
	DebugEndTime "GetTriggerMode"
	
	return $result
}

proc fGetProductRegistrationNames {productRegistrationNames} {
	upvar $productRegistrationNames names
	set names ""
	DebugStartTime
	Debug "In GetProductRegistrationNames" 8
	
	set path [ConvertXPath "$::dxp_configurations/attribute::Name"]
	set templatesCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $templatesCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $names] > 0 && [string length $match] > 0} {
				append names "$::sendDelimiter"
			}
			
			append names $match
		}
	}
	
	DebugEndTime "GetProductRegistrationNames"
	return $result
}

proc fGetParameterSetNames {parameterSetNames} {
	upvar $parameterSetNames names
	set names ""
	DebugStartTime
	Debug "In GetParameterSetNames" 8
	
	set path [ConvertXPath "$::dxp_parametersets/attribute::Name"]
	set templatesCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $templatesCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $names] > 0 && [string length $match] > 0} {
				append names "$::sendDelimiter"
			}
			
			append names $match
		}
	}
	
	DebugEndTime "GetParameterSetNames"
	return $result
}

proc fGetTemplateListNames {templateListNames} {
	upvar $templateListNames names
	set names ""
	DebugStartTime
	Debug "In GetTemplateListNames" 8
	
	set path [ConvertXPath "$::dxp_templatelists/attribute::Name"]
	set templatesCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $templatesCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $names] > 0 && [string length $match] > 0} {
				append names "$::sendDelimiter"
			}
			
			append names $match
		}
	}
	
	DebugEndTime "GetTemplateListNames"
	return $result
}

proc fGetTemplateSequenceNames {templateSequenceNames} {
	upvar $templateSequenceNames names
	set names ""
	DebugStartTime
	Debug "In GetTemplateSequenceNames" 8
	
	set path [ConvertXPath "$::dxp_templatesequences/attribute::Name"]
	set templatesCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $templatesCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $names] > 0 && [string length $match] > 0} {
				append names "$::sendDelimiter"
			}
			
			append names $match
		}
	}
	
	DebugEndTime "GetTemplateSequenceNames"
	return $result
}

proc fGetTemplateBatchNames {templateBatchNames} {
	upvar $templateBatchNames names
	set names ""
	DebugStartTime
	Debug "In GetTemplateBatchNames" 8
	
	set path [ConvertXPath "$::dxp_templatebatches/attribute::Name"]
	set templatesCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\>\n</Command>"
	StackCommand $templatesCommand
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</" $response]
		
		foreach {all match} $matches {
			if {[string length $names] > 0 && [string length $match] > 0} {
				append names "$::sendDelimiter"
			}
			
			append names $match
		}
	}
	
	DebugEndTime "GetTemplateBatchNames"
	return $result
}

proc fSetDateChange {varData} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetDateChange" 8
	
	if {[regexp "\(?:.*$::receiveDelimiter\)\{0,1\}.+$::receiveDelimiter.*$::receiveDelimiter" $varData] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $varData" 2
	} else {
		while {[regexp "\(.*$::receiveDelimiter\)\{0,1\}\(.+\)$::receiveDelimiter\(\[0-9\]+\)$::receiveDelimiter" $varData all varData varName value]} {
			set result [fSetDateChangeValue $varName $value 0]
			
			if {$result != 0} {
				break
			}
		}
	}
	
	DebugEndTime "SetDateChange"
	
	return $result
}

proc fGetDateChange {values  resultData} {
	upvar $resultData resultValues
	set resultValues ""
	DebugStartTime
	Debug "In GetDateChange" 8
	
	set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values]
	set path ""
	
	foreach {all varName} $matches {
		if {[string length $path] > 0} {
			append path "|"
		}
		append path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/attribute::Name|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/*/DateChangeOffset"]
	}
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</\[^<\]*<DateChangeOffset>\(\[^<\]*\)</" $response]
		
		foreach {all varName dateOffset} $matches {
			if {[string length $resultValues] > 0} {
				append resultValues "$::sendDelimiter"
			}
			
			append resultValues $varName$::sendDelimiter$dateOffset
		}
	}
	
	DebugEndTime "GetDateChange"
	
	return $result
}

proc fSetDateChangeValue {varName value {stack 0}} {
	set result 0
	Debug "In SetDateChangeValue" 8
	
	set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/Date/DateChangeOffset"]
	set command "<Command Action=\"$::cmd_modified\" Location=\"$path\">\n<DateChangeOffset>$value</DateChangeOffset></Command>"
	
	StackCommand $command
	
	if {$stack == 0} {
		set result [SendCommandStack response]
	}
	
	return $result
}

proc fSetLayerMarking {values} {
	set result $::dec_parseerror
	DebugStartTime
	Debug "In SetLayerMarking" 8
	
	if {[regexp "\(?:.*$::receiveDelimiter\)\{0,1\}.+$::receiveDelimiter.*$::receiveDelimiter" $values] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $values" 2
	} else {
		while {[regexp "\(.*$::receiveDelimiter\)\{0,1\}\(.+\)$::receiveDelimiter\(\[0-9\]+\)$::receiveDelimiter" $values all values layerName value]} {
			set path [ConvertXPath "$::actualTemplatePath/Layers/Layer\[attribute::Name=\"$layerName\"\]/LayerRepeat"]
			set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><LayerRepeat>$value</LayerRepeat></Command>"
			
			StackCommand $command
			set result [SendCommandStack response]
			
			if {$result != 0} {
				break
			}
		}
	}
	
	DebugEndTime "SetLayerMarking"
	
	return $result
}

proc fGetLayerMarking {values  resultData} {
	upvar $resultData resultValues
	set resultValues ""
	DebugStartTime
	Debug "In GetLayerMarking" 8
	
	set matches [regexp -all -inline "\(\[^$::receiveDelimiter\]*\)$::receiveDelimiter" $values]
	set path ""
	
	foreach {all layerName} $matches {
		if {[string length $path] > 0} {
			append path "|"
		}
		append path [ConvertXPath "$::actualTemplatePath/Layers/Layer\[attribute::Name=\"$layerName\"\]/attribute::Name|$::actualTemplatePath/Layers/Layer\[attribute::Name=\"$layerName\"\]/LayerRepeat"]
	}
	
	set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"\></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	
	if {$result == 0} {
		set matches [regexp -all -inline "<Name>\(\[^<\]*\)</\[^<\]*<LayerRepeat>\(\[^<\]*\)</" $response]
		
		foreach {all varName repeatValue} $matches {
			if {[string length $resultValues] > 0} {
				append resultValues "$::sendDelimiter"
			}
			
			append resultValues $varName$::sendDelimiter$repeatValue
		}
	}
	
	DebugEndTime "GetLayerMarking"
	
	return $result
}

proc fGetRemainingBufferAmount {values resultdata} {
	upvar $resultdata remainingBufferAmount
	set remainingBufferAmount ""
	set result 0
	set msStart [clock clicks -milliseconds]
	
	if {[regexp "(.*\)$::receiveDelimiter" $values all varName] != 1} {
		set result $::dec_parseerror
		Debug "Failed to Parse $values" 2
	} else {
		set result [fGetRemainingBufferAmountValue $varName remainingBufferAmount]
	}
	Debug "Elapsed Time for GetRemainingBufferAmount = [expr [clock clicks -milliseconds] - $msStart]" 4
	return $result
}

proc fGetRemainingBufferAmountValue {varName resultdata} {
	upvar $resultdata remainingBufferAmount
	set remainingBufferAmount ""
	set msStart [clock clicks -milliseconds]
	set result 0
	
	set path [ConvertXPath "count($::actualTemplatePath/Variables/Variable\[attribute::Name=&quot;$varName&quot;\]/Prompt/ValueQueues/ValueQueue\[attribute::Processed=&quot;false&quot;\]/QueueValue)-$::actualTemplatePath/Variables/Variable\[attribute::Name=&quot;$varName&quot;\]/Prompt/ValueQueues/ValueQueue\[attribute::Processed=&quot;false&quot;\]/attribute::NextValueIndex"]
	set command "<Command Action=\"$::cmd_execxpath\" Location=\"$path\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	if {$result == 0} {
		if {[regexp ">\\n(\[^<\]*)</" $response all amount] != 1} {
			set result $::dec_parseerror
			Debug "Failed to Parse $response" 2
		} else {
			Debug "amount = $amount" 8
			if {[regexp "nan" $amount]} {
				set result 0
				set remainingBufferAmount 0
			} else {
				set remainingBufferAmount [format "%g" [expr $amount]]
			}
		}
	}
	Debug "Elapsed Time for GetRemainingBufferAmountValue = [expr [clock clicks -milliseconds] - $msStart]" 4
	return $result
}

proc fAddBufferData {values} {
	set result 0
	
	set msStartAll [clock clicks -milliseconds]
	
	if {$result == 0} {
		while {[regexp "\\t?\(\[^$::receiveDelimiter\]*\);\(\[^\\t\]*\)\(.*\)" $values all varName varValues values]} {
			
			if {$result == 0} {
				set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]/Prompt/ValueQueues/QueueStatus"]
				set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
				
				StackCommand $command
				set result [SendCommandStack response]
				
				if {$result == 45023} {
					set result [fCreateValueQueueStructure $varName $varValues]
				} elseif {$result == 0} {
					set result [fAppendValueQueue $varName $varValues]
				}
			}
			
			if {$result == 0} {
				set result [fReactivateQueue $varName]
			}
			
			if {$result == 0} {
				set result [fCleanUsedQueues $varName]
			}
		}
	}
	
	Debug "Elapsed Time for AddBufferData = [expr [clock clicks -milliseconds] - $msStartAll]" 4
	
	return $result
}

proc fCreateValueQueueStructure {variableName varValues} {
	set msStart [clock clicks -milliseconds]
	
	Debug "In CreateValueQueueStructure" 8
	
	set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=&quot;$variableName&quot;\]/Prompt\[1\]"]
	set strDmyDomCommand "<Command Action=\"$::cmd_appendchild\" Location=\"$path\">"
	set valueQueueID [GenerateUniqueID]
	set strDmyDom "<ValueQueues><QueueStatus>"
	append strDmyDom "<UseQueues>true</UseQueues>"
	append strDmyDom "<ActiveQueueID>$valueQueueID</ActiveQueueID>"
	append strDmyDom "<ActiveQueueValueIndex>0</ActiveQueueValueIndex>"
	append strDmyDom "<AutoQueueAdvance>true</AutoQueueAdvance>"
	append strDmyDom "<AutoQueueReUse>false</AutoQueueReUse>"
	append strDmyDom "<AutoQueueDelete>true</AutoQueueDelete>"
	append strDmyDom "</QueueStatus>"
	append strDmyDom [fCreateValueQueueElement $varValues $valueQueueID]
	append strDmyDom "</ValueQueues>"
	set strDmyDomCommandEnd "</Command>"
	
	StackCommand $strDmyDomCommand$strDmyDom$strDmyDomCommandEnd
	set result [SendCommandStack response]
	
	Debug "Elapsed Time for CreateValueQueueStructure = [expr [clock clicks -milliseconds] - $msStart]" 4
	
	return $result
}

proc fCreateValueQueueElement {varValues queueID} {
	set msStart [clock clicks -milliseconds]
	set strDmyDom "<ValueQueue ID=\"$queueID\" NextValueIndex=\"0\" Processed=\"false\">"
	
	while {[regexp "\(\[^;\]*\);\(.*\)" $varValues all varValue varValues]} {
		append strDmyDom "<QueueValue>[string map $::sendMapping $varValue]</QueueValue>"
	} 
	
	if {[string length $varValues] > 0} {
		append strDmyDom "<QueueValue>[string map $::sendMapping $varValues]</QueueValue>"
	}
	
	
	append strDmyDom "</ValueQueue>"
	
	Debug "Elapsed Time for CreateValueQueueElement = [expr [clock clicks -milliseconds] - $msStart]" 4
	return $strDmyDom
}

proc fAppendValueQueue {variableName varValues} {
	set msStart [clock clicks -milliseconds]
	
	Debug "In AppendValueQueue" 8
	
	set newQueueID [GenerateUniqueID]
	set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=&quot;$variableName&quot;\]/Prompt/ValueQueues"]
	set strDmyDomCommand "<Command Action=\"$::cmd_appendchild\" Location=\"$path\">"
	set strDmyDom [fCreateValueQueueElement $varValues $newQueueID]
	set strDmyDomCommandEnd "</Command>"
	
	StackCommand $strDmyDomCommand$strDmyDom$strDmyDomCommandEnd
	set result [SendCommandStack response]
	
	Debug "Elapsed Time for AppendValueQueue = [expr [clock clicks -milliseconds] - $msStart]" 4
	
	return $result
}

proc fReactivateQueue {variableName} {
	set msStart [clock clicks -milliseconds]
	set result 0
	
	fGetStatusCode statusCode
	
	if {$statusCode != 1} {
	
		set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$variableName\"\]/Prompt/ValueQueues/QueueStatus/UseQueues|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$variableName\"\]/Prompt/ValueQueues/ValueQueue\[attribute::Processed=\"false\"\]/attribute::ID|$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$variableName\"\]/Prompt/ValueQueues/ValueQueue\[attribute::Processed=\"false\"\]/attribute::NextValueIndex"]
		set command "<Command Action=\"$::cmd_getsubtree\" Location=\"$path\"></Command>"
		
		StackCommand $command
		set result [SendCommandStack response]
		
		if {$result == 0} {
			if {[regexp "<UseQueues>\(\[^<\]*\)</" $response all useQueues] != 1} {
				set result $::dec_parseerror
				Debug "Failed to Parse $response" 2
			}
			
			if {$result == 0} {
				if {$useQueues == false} {
					if {[regexp "<ID>\(\[^<\]*\)</" $response all nextQueueID] != 1} {
						set result $::dec_parseerror
						Debug "Failed to Parse $response" 2
					}
					if {[regexp "<NextValueIndex>\(\[^<\]*\)</" $response all nextQueueValueIndex] != 1} {
						set result $::dec_parseerror
						Debug "Failed to Parse $response" 2
					}
					
					if {$result == 0} {
						
						set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$variableName\"\]/Prompt/ValueQueues/QueueStatus/ActiveQueueID"]
						set command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><ActiveQueueID>$nextQueueID</ActiveQueueID></Command>"
						set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$variableName\"\]/Prompt/ValueQueues/QueueStatus/ActiveQueueValueIndex"]
						append command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><ActiveQueueValueIndex>$nextQueueValueIndex</ActiveQueueValueIndex></Command>"
						set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$variableName\"\]/Prompt/ValueQueues/QueueStatus/UseQueues"]
						append command "<Command Action=\"$::cmd_modified\" Location=\"$path\"><UseQueues>true</UseQueues></Command>"
						
						StackCommand $command
						set result [SendCommandStack response]
					}
				}
			}
		}
	}
	
	Debug "Elapsed Time for ReactivateQueue = [expr [clock clicks -milliseconds] - $msStart]" 4
	return $result
}

proc fCleanUsedQueues {variableName} {
	set msStart [clock clicks -milliseconds]
	set result 0
	fGetStatusCode statusCode
	
	if {$statusCode != 1} {
		
		set obsoleteQueues [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$variableName\"\]/Prompt/ValueQueues/ValueQueue\[attribute::Processed=\"true\"\]/attribute::ID"]
		set obsoleteQueuesCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$obsoleteQueues\"\>\n</Command>"
		
		StackCommand $obsoleteQueuesCommand
		set result [SendCommandStack response]
		
		set deleteCommand ""
		if {$result == 0} {
			set matches [regexp -all -inline "<ID>\(\[^<\]*\)</" $response]
			
			foreach {all match} $matches {
				set path [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$variableName\"\]/Prompt/ValueQueues/ValueQueue\[attribute::ID=\"$match\"\]"]
				append deleteCommand "<Command Action=\"$::cmd_delete\" Location=\"$path\">"
				append deleteCommand "<ValueQueue ID=\"$match\"></ValueQueue>"
				append deleteCommand "</Command>\n"
			}
			
			StackCommand $deleteCommand
			set result [SendCommandStack response]
		} else {
			set result 0
		}
	}
	
	Debug "Elapsed Time for CleanUsedQueues = [expr [clock clicks -milliseconds] - $msStart]" 4
	
	return $result
}

proc fClearBufferData {values} {
	set result 0
	set msStart [clock clicks -milliseconds]
	
	if {[string length $values] == 0} {
		set allQueues [ConvertXPath "$::actualTemplatePath/Variables/Variable\[Prompt/ValueQueues\]/attribute::ID"]
		set allQueuesCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$allQueues\"\>\n</Command>"
		
		StackCommand $allQueuesCommand
		set result [SendCommandStack response]
		
		if {$result == 0} {
			set matches [regexp -all -inline "<ID>\(\[^<\]*\)</" $response]
			Debug "matches found = [expr {[llength $matches] / 2}]" 8
			
			foreach {all match} $matches {
				lappend variableIds $match
			}
		}
		
	} else {
		while {[regexp "\(\[^$::receiveDelimiter\]+\)$::receiveDelimiter?\(.*\)" $values all varName values]} {
			
			set specificQueue [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::Name=\"$varName\"\]\[Prompt/ValueQueues\]/attribute::ID"]
			set specificQueueCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$specificQueue\"\>\n</Command>"
			
			StackCommand $specificQueueCommand
			set result [SendCommandStack response]
			
			if {$result == 0} {
				if {[regexp "<ID>\(\[^<\]*\)</" $response all value] != 1} {
					set result $::dec_parseerror
					Debug "Failed to Parse $response" 2
				} else {
					lappend variableIds $value
				}
			}
		}
	}
	
	if {$result == 0} {
		set obsoleteQueuesCommand ""
		
		for {set i 0} {$i < [llength $variableIds]} {incr i} {
			set obsoleteQueues [ConvertXPath "$::actualTemplatePath/Variables/Variable\[attribute::ID=\"[lindex $variableIds $i]\"\]/Prompt/ValueQueues"]
			append obsoleteQueuesCommand "<Command Action=\"$::cmd_delete\" Location=\"$obsoleteQueues\"\><ValueQueues></ValueQueues></Command>"
		}
		
		StackCommand $obsoleteQueuesCommand
		set result [SendCommandStack response]
	}
	
	Debug "Elapsed Time for ClearBufferData = [expr [clock clicks -milliseconds] - $msStart]" 4
	return $result
}

proc fRunXMLCommand {values resultdata} {
	upvar $resultdata response
	set response ""
	set result 0
	DebugStartTime
	
	if {[regexp "(.*)$::receiveDelimiter" $values all command]} {
		set command [string map $::commandSendMapping $command]
		StackCommand $command
		set result [SendCommandStack response]
	} else {
		set result $::dec_parseerror
		Debug "Failed to Parse $values" 2
	}
	
	#GS 06.12.2018
	#no removing of CR LF in repponse for gettemplategraphic
	#to prevent missing value delimiters (CR LF is delimiter in svg spec)
	
	if {[regexp "\(?i\)\(\<Command Action=\"gettemplategraphic\")" $values]} {
		Debug "templategrphic command detectet- no mapping" 4
	} else {
		set response [string map $::commandOutputMapping $response]
		Debug "no templategrphic command detectet- remove CR LF" 4
	}
	
	DebugEndTime "RunXMLCommand"
	
	return $result
}