lappend auto_path [file dirname [info script]]
package provide XMLCommunication 1.6.7

#AR 19.07.2018
#revision 7 10% lower CPU load on high speed application Chameleon
#block communication improvement
#restart reworked - -will be restarted automatically after 100ms
#xml parser rewritten - sometimes "unknown command was received" and data was lost in recursive calls of the parser
#encoding added for CMark 4.x systems (TCL-78)
#set socket to non-blocking and added catch-block for disconnect (TCL-79)
#optimzed ProcessCommands for checking individual commands by location without regexp

#Connection
set channel 0
set laserIP 127.0.0.1
set xmlPort 2255
set xmlStopPort 2211

set ignoreTemplateChange 0

#Data
set inputBuffer ""
set nextstartmark 0
set cmd_Stack ""
set cmd_StackInt ""

#Standards
set actualTemplateID ""
set actualTemplatePath ""
set actualTemplateType ""

set systemState ""

set configurationID ""
set parametersetID ""

set markingCounter 0
set productCounter 0

set commandqueue 0
set processingqueue 0
set nextindex 0
set commandlist {}

set startPID ""

proc StartInterface {} {
	set ::startPID  ""
	set result 0
	set	::inputBuffer ""
	set ::nextstartmark 0
	
	Debug "Starting interface" 1
	
	if { [catch {set ::channel [socket $::laserIP $::xmlPort]} msg] } {
    	Debug "Open Socket failed $::laserIP $msg" 1
    	set result $::dec_communicationfailed
  	} else {
		Debug "Connection established" 1
		
	 	fconfigure $::channel -blocking 0 -translation {binary binary}
		fileevent  $::channel readable IncomingMessage
		set ::isProcessing 1
		set result [InitiallyReadStandards]
		set ::isProcessing 0
		
		if {$::processingqueue <= 0} {		
			if {$::commandqueue > 0} {
				Debug "Rescheduling queue processing from StartInterface..." 7
				after idle [list after 0 ProcessCommandList]
			} elseif {$::clientcommandqueue > 0} {
				Debug "Rescheduling clientqueue processing from StartInterface..." 7
				after idle [list after 0 ProcessClientCommandList]	
			}
		}
	}
	
	if {$result} {
		Debug "Interface initialisation failed with code \"$result\"" 1
		restartInterface
	} else {
		Debug "Interface started" 1
	}
	
  	return $result
}

proc restartInterface {} {
	Debug "Closing interface" 1
	
	catch {close $::channel}
	set ::interfaceStatus -1
	set ::channel 0
	
	ProcessBuffer "NULL"

	set ::commandqueue 0
	set ::processingqueue 0
	set ::nextindex 0
	set ::commandlist {}
	set ::inputBuffer ""
	set ::nextstartmark 0	
	
	Debug "Scheduling interface restart" 1
	
	if {$::startPID == ""} {
		set ::startPID [after idle [list after 100 [list StartInterface]]]
	} 		
}

proc StopLaser {} {
	set result 0
	
	if { [catch {set stopChannel [socket $::laserIP $::xmlStopPort]} msg] } {
    	Debug "Connecting to Stop port failed: $msg" 1
    	set result $::dec_communicationfailed
	} else {
		if { [catch {close $stopChannel} msg] } {
			Debug "Closing Stop port failed: $msg" 1
			set result $::dec_communicationfailed
		}
	}	
	return $result
}

proc InitiallyReadStandards {} {
	
	StackCommand $::dc_getactualtemplate 1
	set result [SendCommandStack response 1]
	
	if {$result == 0} {
		if {[regexp "<ActualTemplate>\(\[^<\]*\)</" $response all newID] != 1} {
			set result $::dec_parseerror
		} else {
			UpdateActualTemplateID $newID 1
		}
	}
	
	StackCommand $::dc_getstatus 1
	set result [SendCommandStack response 1]
	
	if {$result == 0} {
		if {[regexp "<SystemState>\(\[^<\]*\)" $response all newState] != 1} {
			set result $::dec_parseerror
		} else {
			UpdateCurrentState $newState
		}
	}
	
	StackCommand $::dc_getproductcounter 1
	set result [SendCommandStack response 1]
	
	if {$result == 0} {
		if {[regexp "<ProductCounterValue>\(\[^<\]*\)" $response all productCounterValue] != 1} {
			set result $::dec_parseerror
		} else {
			UpdateProductCounterValue $productCounterValue
		}
	}
	
	StackCommand $::dc_getmarkingcounter 1
	set result [SendCommandStack response 1]
	
	if {$result == 0} {
		if {[regexp "<PrintCounterValue>\(\[^<\]*\)" $response all markingCounterValue] != 1} {
			set result $::dec_parseerror
		} else {
			UpdateMarkingCounterValue $markingCounterValue
		}
	}
	
	return $result
}

set loopCounter 0
set chars_to_readout 0
set xmlheaderlength [expr {[string length $::XML_Header] -2}]

proc IncomingMessage {} {
	if {[eof $::channel]} { 
		Debug "channel received EOF (Port 2255) was closed" 1
		restartInterface
	} else {
		if {$::channel != 0} {
			#read out complete buffer
			append ::inputBuffer [read $::channel]			
			set ::chars_to_readout [string length $::inputBuffer]

			while {[expr {$::chars_to_readout > 0}]} { 				

				#Debug "bufferlength: $::chars_to_readout" 1
				
				#a new xml doc is expected	-> get header and parse length if possible				
				set startmark [string first "XML:" $::inputBuffer $::nextstartmark]					
				if {[expr {$startmark >= 0}]} {			       	
					#header_endmark keeps index of colon behind length information
					set header_endmark [string first ":" $::inputBuffer [expr {$startmark+4}]]
					if {[expr {$header_endmark >= 0}]} {
											
						#read out length of document
						set doclength [string range $::inputBuffer [expr {$startmark + 4}] [expr {$header_endmark -1}]]
						#Debug "headerlength: [expr {$header_endmark - $startmark + 1}] | doclength: $doclength | total: [expr {$doclength + $header_endmark - $startmark + 1}]" 1
						
						if {![string is digit $doclength]} {
							Debug "channel received wrong XML length: \"$doclength\"" 1
							restartInterface 
							break
						}
											
						#calculate next start index of document
						set message_endmark [expr {$header_endmark + $doclength}]					
						#Debug "chars_to_readout: $::chars_to_readout | startmark: $startmark | message_endmark: $message_endmark | count: [expr {$message_endmark-$startmark+1}]" 1

						#check if message is complete
						if {[expr {$::chars_to_readout > $message_endmark}]} {	
							set ::nextstartmark  [expr {$message_endmark + 1}]
														
							#Debug "processing start: $::loopCounter" 1
							#incr ::loopCounter 1					
							ProcessBuffer [encoding convertfrom utf-8 [string range $::inputBuffer [expr {$header_endmark + $::xmlheaderlength + 1}] $message_endmark]]
							#incr ::loopCounter -1
							#Debug "processing end: $::loopCounter" 1
							#Debug "chars_to_readout: $::chars_to_readout | nextstartmark: $::nextstartmark" 1							
							
							if {[expr {$::chars_to_readout == $::nextstartmark}]} {
								set ::inputBuffer ""
								set ::nextstartmark 0
								set ::chars_to_readout 0
								Debug "input buffer deleted" 6
								break
							} 
							
						} else {							
							Debug "not enough data for processing... [expr {$message_endmark-$::chars_to_readout+1}] chars missing" 2
							break
						}						
					} else {
						Debug "no header_endmark found...\r\n[string range $::inputBuffer $::nextstartmark [expr {[string length $::inputBuffer]-1}]]" 2
						break
					}			
				} else {
					Debug "no startmark found...\r\n[string range $::inputBuffer $::nextstartmark [expr {[string length $::inputBuffer]-1}]]" 2
					break				
				}
			}
			
			#remove already processed data from buffer
			if {[expr {$::nextstartmark > 0}]} {				
				set ::inputBuffer [string range $::inputBuffer $::nextstartmark [expr {[string length $::inputBuffer] -1}]]
				Debug "temp buffer reduced to ($::nextstartmark - [expr {[string length $::inputBuffer] -1}]): $::inputBuffer" 1
				set ::nextstartmark 0
			}
		}
	}
}

proc ProcessBuffer {bufferData} { 

	if { [expr {[string first <Com [string range $bufferData 0 6]] > 0}] } {

		if {[expr {$::debugLevel >= 10}]} {
			Debug "Received command: $bufferData" 10
		}	

		if {[expr {$::commandqueue > 0 || $::isProcessing > 0}]} {
			if {[llength $::commandlist] > 2000} {
				Debug "Ignoring internal command, commandlist exceeds 2000" 1
			} else {			
				incr ::commandqueue 1
				if {[expr $::debugLevel >= 7]} {
					Debug "Queueing internal command due to pending commands at [llength $::commandlist], queuelength: $::commandqueue" 7
				}
				lappend ::commandlist $bufferData
			}			
		} else {
			incr ::commandqueue 1
			ProcessCommands bufferData
		}
		
	} else {
		if {[expr {$::debugLevel >= 6}]} {
			Debug "Received response: $bufferData" 6
		}		
		set ::syncresponse $bufferData 
  	}
}

proc ProcessCommandList {} {
	set ::processingqueue 1
	while {[llength $::commandlist] > $::nextindex} {
		set data [lindex $::commandlist $::nextindex]
		if {[ProcessCommands data] >= 0 } {
			incr ::nextindex 1
			Debug "Updateing..." 7
			update
		} else {
			set ::processingqueue 0
			return
		}
	}
	
	Debug "Clearing queue..." 7
	set ::nextindex 0
	set ::commandlist {}
	set ::processingqueue 0
	
	if {$::clientcommandqueue > 0} {
		Debug "Rescheduling clientqueue processing from internal..." 7
		after idle [list after 0 ProcessClientCommandList]	
	}	
}

proc ProcessCommands {data} {
	#queue processing
	if { [expr {$::isProcessing > 0}]} {		
		return -1		
	} else {
		incr ::commandqueue -1
		set ::isProcessing 1
		upvar 1 $data commandData
		
		if {[expr $::debugLevel >= 7]} {
			Debug "Processing internal command, index: $::nextindex / length: [llength $::commandlist]" 7
		}
		set msStart [clock clicks -milliseconds]
		
		ProcessCommandsExtension $commandData
		
		set lastIndex 0		
		while {1} {
			set location [GetStringBetween commandData "Location=\"" "\"" lastIndex $lastIndex]	
			if {[expr {$lastIndex < 0}]} {
				break
			}			
			
			#Debug "Running $lastIndex" 1
			
			if {[expr {[string first "SystemState" $location 25] > 0}]} {
				set newState [GetStringBetween commandData "<SystemState>" "<" lastIndex $lastIndex]		
				if {[expr {[string length $newState] > 0}]} {
					UpdateCurrentState $newState
					Debug "SystemState changed" 55
				}			
			
			} elseif {[expr {[string first "PrintCounterValue" $location 25] > 0}]} {
				set markingCounter [GetStringBetween commandData "<PrintCounterValue>" "<" lastIndex $lastIndex]		
				if {[expr {[string length $markingCounter] > 0}]} {
					UpdateMarkingCounterValue $markingCounter
					Debug "markingCounter changed" 5
				}		
			
			} elseif {[expr {[string first "ProductCounterValue" $location 25] > 0}]} {
				set productCounter [GetStringBetween commandData "<ProductCounterValue>" "<" lastIndex $lastIndex]		
				if {[expr {[string length $productCounter] > 0}]} {
					UpdateProductCounterValue $productCounter
					Debug "productCounter changed" 5
				}	
			
			} elseif {[expr {[string first "ActualTemplate" $location 25] > 0}]} {
				set newID [GetStringBetween commandData "<ActualTemplate>" "<" lastIndex $lastIndex]		
				if {[expr {[string length $newID] > 0 && $::ignoreTemplateChange == 0 }]} {
					UpdateActualTemplateID $newID 1
					Debug "ActualTemplateID changed" 5
				}
			
			} elseif {[expr {[string first "ErrorMessage" $location 25] > 0}]} {
				set errorMessage [GetStringBetween commandData "<ErrorMessage ID" ">" lastIndex $lastIndex]
				if {[expr {[string length $errorMessage] > 0}]} {
					if {[regexp "Action=\"$::cmd_appendchild\"" $commandData]} {
						ErrorAppended
						Debug "Error appended" 5
					}
				}				
			} 
		}		
		
		Debug "Elapsed Time for ProcessCommands = [expr [clock clicks -milliseconds] - $msStart]" 4
		
		set ::isProcessing 0	
				
		if { [expr {$::processingqueue <= 0}]} {		
			if {[expr {$::commandqueue > 0}]} {
				Debug "Rescheduling queue processing from internal..." 7
				after idle [list after 0 ProcessCommandList]
			} elseif {[expr {$::clientcommandqueue > 0}]} {
				Debug "Rescheduling clientqueue processing from internal..." 7
				after idle [list after 0 ProcessClientCommandList]	
			}
		}
		
		return 0
	}			
}

proc UpdateCurrentState {newState} {
	set ::systemState $newState
	ActualStateChanged $newState
	if {[llength [info proc ActualStateChangedExtension]] > 0} {
		ActualStateChangedExtension $newState
	}
}

proc UpdateProductCounterValue {productCounterValue} {
	set ::productCounter $productCounterValue
	ProductCounterValueChanged
	if {[llength [info proc ProductCounterValueChangedExtension]] > 0} {
		ProductCounterValueChangedExtension
	}
}

proc UpdateMarkingCounterValue {markingCounterValue} {
	set ::markingCounter $markingCounterValue
	MarkingCounterValueChanged
	if {[llength [info proc MarkingCounterValueChangedExtension]] > 0} {
		MarkingCounterValueChangedExtension
	}
}

proc UpdateActualTemplateID {newID {internalCom 0}} {
	set ::actualTemplateID $newID
	UpdateCurrentJobPath $internalCom
	ActualTemplateChanged
	if {[llength [info proc ActualTemplateChangedExtension]] > 0} {
		ActualTemplateChangedExtension
	}
}

proc UpdateCurrentJobPath {{internalCom 0}} {
	if {[GetCurrentJobPath templatePath templateType $internalCom] == 0} {
		set ::actualTemplatePath $templatePath
		set ::actualTemplateType $templateType
	}
}

proc GetCurrentJobPath {templatePath templateType {internalCom 0}} {
	upvar $templatePath path
	upvar $templateType type
	
	set path ""
	set type ""
	
	set templatePath [ConvertXPath "/Root/Databases/Database/Templates/Template\[attribute::ID=\"$::actualTemplateID\"\]"]
	set templateCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$templatePath/ConfigurationID|$templatePath/ParameterSetID\">\n</Command>"
	
	StackCommand $templateCommand $internalCom
	set result [SendCommandStack response $internalCom]
	
	if {$result == 0} {
		set path $templatePath
		set type Template
		
		if {[regexp "<ConfigurationID>\(\[^<\]*\)</" $response all configurationId] == 1} {
			set ::configurationID $configurationId
		}
		
		if {[regexp "<ParameterSetID>\(\[^<\]*\)</" $response all parametersetId] == 1} {
			set ::parametersetID $parametersetId
		}
	} elseif {$result == 45023} {
		set templateListPath [ConvertXPath "/Root/Databases/Database/Templates/Template\[attribute::ID=/Root/Databases/Database/TemplateLists/TemplateList\[attribute::ID=\"$::actualTemplateID\"\]/TemplateListElements/TemplateListElement/ListTemplateID\]"]
		set templateListCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$templateListPath/ConfigurationID|$templateListPath/ParameterSetID\">\n</Command>"
		
		StackCommand $templateListCommand $internalCom
		set templateListResult [SendCommandStack templateListResponse $internalCom]
		
		if {$templateListResult == 0} {
			set path $templateListPath
			set type TemplateList
			set result $templateListResult
			
			if {[regexp "<ConfigurationID>\(\[^<\]*\)</" $templateListResponse all configurationId] == 1} {
				set ::configurationID $configurationId
			}
			
			if {[regexp "<ParameterSetID>\(\[^<\]*\)</" $templateListResponse all parametersetId] == 1} {
				set ::parametersetID $parametersetId
			}
		} else {
			set templateSequencePath [ConvertXPath "/Root/Databases/Database/Templates/Template\[attribute::ID=/Root/Databases/Database/TemplateSequences/TemplateSequence\[attribute::ID=\"$::actualTemplateID\"\]/TemplateSequenceElements/SequenceTemplateID\]"]
			set templateSequenceCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$templateSequencePath/ConfigurationID|$templateSequencePath/ParameterSetID\">\n</Command>"
			
			StackCommand $templateSequenceCommand $internalCom
			set templateSequenceResult [SendCommandStack templateSequenceResponse $internalCom]
			
			if {$templateSequenceResult == 0} {
				set path $templateSequencePath
				set type TemplateSequence
				set result $templateSequenceResult
				
				if {[regexp "<ConfigurationID>\(\[^<\]*\)</" $templateSequenceResponse all configurationId] == 1} {
					set ::configurationID $configurationId
				}
				
				if {[regexp "<ParameterSetID>\(\[^<\]*\)</" $templateSequenceResponse all parametersetId] == 1} {
					set ::parametersetID $parametersetId
				}
			} else {
				set templateBatchPath [ConvertXPath "/Root/Databases/Database/Templates/Template\[attribute::ID=/Root/Databases/Database/TemplateBatches/TemplateBatch\[attribute::ID=\"$::actualTemplateID\"\]/TemplateBatchElements/BatchTemplateID\]"]
				set templateBatchCommand "<Command Action=\"$::cmd_getsubtree\" Location=\"$templateBatchPath/ConfigurationID|$templateBatchPath/ParameterSetID\">\n</Command>"
				
				StackCommand $templateBatchCommand $internalCom
				set templateBatchResult [SendCommandStack templateBatchResponse $internalCom]
				
				if {$templateBatchResult == 0} {
					set path $templateBatchPath
					set type TemplateBatch
					set result $templateBatchResult
					
					if {[regexp "<ConfigurationID>\(\[^<\]*\)</" $templateBatchResponse all configurationId] == 1} {
						set ::configurationID $configurationId
					}
					
					if {[regexp "<ParameterSetID>\(\[^<\]*\)</" $templateBatchResponse all parametersetId] == 1} {
						set ::parametersetID $parametersetId
					}
				}
			}
		}
	}
	
	if {$result != 0} {
		Debug "Failed to Read Configuration and ParameterSet" 1
	}
	
	return $result
}

proc SendMessage {msg} {

	#parameter message string
	#answer reply to answer
	# Message gets a Header and is send using the synchron port - direct answer is put on ::syncresponse

	set nettolength [string bytelength $msg]
	
	set length [expr $nettolength + 5]
	set msgbuffer "$::XML_PreHeader$nettolength:"	
	append msgbuffer $msg
	
	if {[expr $::debugLevel >= 6]} {
		Debug "Sending: $msgbuffer" 6
	}
	
	set result "NULL"
	
	if {[output_sync $msgbuffer] == 0} {
		# schedule input processing if there is still data in input buffer before waiting 
		if {[expr {$::chars_to_readout > $::nextstartmark}]} {
			Debug "schedule input buffer processing before waiting for answers" 7
			after idle [list after 0 IncomingMessage]			
		}
		vwait ::syncresponse
		set result $::syncresponse
	} else {
		set result "NULL"
	}
	
	return $result
}

proc output_sync {text} {
	if {$::channel == 0 } {
		Debug "No Connection to Laser on Port 2255" 1
		return 1
	}
	set len [string length ":$text"]
	set buff "$len:$text" 
	set rc [script { puts -nonewline $::channel $buff; flush $::channel }]
	if {$rc} {
		Debug "Error sending data to XML port" 1
		restartInterface 
	}
	return $rc
}

proc StackCommand {command {internalCom 0}} {
	if {$internalCom} {
		append ::cmd_StackInt $command
	} else {
		append ::cmd_Stack $command
	}
}

proc SendCommandStack {data {internalCom 0}} {
	upvar $data response
	set result 0
	
	if {$internalCom} {
		set command $::cmd_StackInt
		set ::cmd_StackInt ""
	} else {
		set command $::cmd_Stack		
		set ::cmd_Stack ""		
	}
	
	if {[string length $command] > 0} {	
		set result [SendXMLCommand $command response]
		set ::cmd_StackInt ""	
	}
	
	return $result
}

proc SendXMLCommand {command data} {
	upvar $data response
	set lmsg $::XML_Header
	append lmsg "<Commands>\n"
	append lmsg $command
	append lmsg "</Commands>"
	
	set response [SendMessage [encoding convertto utf-8 $lmsg]]
	
	if {$response != "NULL"} {
		if {[regexp "<Response.*ErrorCode=\"\(\[^\"\]*\)\"" $response all errorCode]} {
			return $errorCode
		}
	}
	
	return $::dec_communicationfailed
}