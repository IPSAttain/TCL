# ZTC extension for Ultimate
# Emulate ZTC Commands for Chameleon Laser only
# Christian Wagner
# special thanks to Stephane and Valerio
# 01.07.2020 V1.0 first release
# Supported Commands: JDA JDU SLA SEL GWN GFT CAF CAW GST GJN GJL GJD GTD TAD SST
# Todo : SAN
# Supported Async Values: STS JOB PRC
# Todo: ERS
package provide Extension 1.6
set extensionVersion 1.0
set extensionName "ZTC Commands for VJ Laser"
set ZTCPort 20005
set ZTCactive 1

set ZTCasyncStatus 0
set ZTCasyncJob 0
set ZTCasyncPrintComplete 0

set ZTCasyncClients {}
set ZTClastState 0
set ZTClastCount 0


proc ParseExtension {command values responseData} {
	upvar $responseData resultdata
	set result 0
	
	switch $command {
		default {
			set result -2
		}
	}
	
	return $result
}
proc ZTCServerAccept {client addr port} {
	lappend ::ZTCasyncClients $client
	fileevent $client readable "ZTCIncommingData $client"
	fconfigure $client -buffering line -translation {auto cr}
}
proc ParseCustomizedProtocolExtension {client data responseData} {
	upvar $responseData resultdata
	set resultdata ""
	set result -2
	
	return $result
}
#Customized Debugging
proc DebugExtension {text level} {
	
}
#Customized Eventhandling
proc ProcessCommandsExtension {commandData} {
	
}
proc ActualTemplateChangedExtension {} {
	if {$::ZTCasyncJob == 1} {
		set result [fGetJob jobName]
		if {$result == 0} {
			ZTCEventNotification "JOB|$jobName|-|"
		}
	}
}
proc ActualStateChangedExtension {newState} {

	if {$::ZTCasyncStatus == 1} {
		switch $newState {
			LaserStatusError2 {
				set state 0
			}
			LaserStatusError1 {
				set state 0
			}
			LaserStatusFatalError {
				set state 0
			}
			LaserStatusKeySwitchOpen {
				set state 0
			}
			LaserStatusStartUp {
				set state 1
			}
			LaserStatusReady {
				set state 4
			}
			LaserStatusStandby {
				set state 4
			}
			LaserStatusMarking {
				set state 3
			}
			LaserStatusWaitForTrigger {
				set state 3
			}
			LaserStatusWaitForTriggerDelay {
				set state 3
			}
			LaserStatusPause {
				set state 3
			}
			LaserStatusPrepareForMarking {
				set state 3
			}
			LaserStatusWaitForPause {
				set state 3
			}
			default {
				set state $newState
			}
		}
		if {$::ZTClastState != $state} {
			set ::ZTClastState $state
			ZTCEventNotification "STS|$state|"
		}
	}
}
proc ProductCounterValueChangedExtension {} {
	
}
proc MarkingCounterValueChangedExtension {} {
	if {$::ZTCasyncJob == 1} {
		ZTCEventNotification "PRC"
	}
}

proc ZTCEventNotification {data} {
	foreach asyncClient $::ZTCasyncClients {
		if {$asyncClient != 0} {
			cSend $asyncClient $data
		}
	}
}

proc ZTCIncommingData {client} {
	gets $client data
	if {[eof $client]} {
		close $client
	} else {
		set data [string trim $data]
		set line [split $data "|"]
		set command [lindex $line 0]
		set command [string tolower $command]
		switch $command {
			sla {
				set jobName [lindex $line 1]
				append jobName "$::receiveDelimiter"
				set result [fSetJob $jobName]
				if {$result == 0} {
					set line [lrange $line 2 end-1]
					# update variables
					foreach varcontent $line {
						regexp {(.*)=(.*)} $varcontent all var content
						set vardata "$var$::receiveDelimiter$content$::receiveDelimiter"
						fSetVars $vardata
					}
					set message "ACK"
					# same behavior than the Clarity Printer send ACK even the variable is not valid
				} else {
					set message "ERR"
				}
			}
			sel {
				set jobName [lindex $line 1]
				append jobName "$::receiveDelimiter"
				set result [fSetJob $jobName]
				if {$result == 0} {
					set line [lrange $line 2 end-1]
					set i 0
					foreach varcontent $line {
						incr i
						set num [format "%02d" $i]
						# leading zero
						set vardata "VarField$num$::receiveDelimiter$varcontent$::receiveDelimiter"
						fSetVars $vardata
					}
					set message "ACK"
				} else {
					set message "ERR"
				}
			}
			jda {
				set line [lrange $line 1 end]
				foreach varcontent $line {
					regexp {(.*)=(.*)} $varcontent all var content
					set vardata "$var$::receiveDelimiter$content$::receiveDelimiter"
					fSetVars $vardata
				}
				set message "ACK"
			}
			jdu {
				set line [lrange $line 1 end-1]
				set i 0
				foreach varcontent $line {
					incr i
					set num [format "%02d" $i]
					set vardata "VarField$num$::receiveDelimiter$varcontent$::receiveDelimiter"
					fSetVars $vardata
				}
				set message "ACK"
			}
			gwn {
				# proc ZTCGetMessages below returns all messages 
				# Warnings firs than Errors - seperated by ^
				set result [ZTCGetMessages Message]
				set message "WRN|[lindex [split $Message "^"] 0]"
			}
			gft {
				# proc ZTCGetMessages below
				set result [ZTCGetMessages Message]
				set message "WRN|[lindex [split $Message "^"] 1]"
			}
			caf {
				set result [fDeleteMessages]
				if {$result == 0} {
					set message "ACK"
				} else {
					set message "ERR"
				}
			}
			caw {
				set result [fConfirmMessages]
				if {$result == 0} {
					set message "ACK"
				} else {
					set message "ERR"
				}
			}
			gst {
				set errorstate 0
				fGetStatusCode statusCode
				switch $statusCode {
					-1 { # Lasersource off
						set state 0
						switch $::systemState {
							LaserStatusError1 {
								set errorstate 2
							}
							LaserStatusError2 {
								set errorstate 2
							}
							LaserStatusFatalError {
								set errorstate 2
							}
							default {
								set errorstate 0
							}
						}
					}
					0 { # Offline
						set state 4
					}
					1 { # running
						set state 3
					}
					default {
						set state 0
					}
				}
				if {$errorstate == 0} {
					set numberofwarning [ZTCGetMessages warnings]
					if {$numberofwarning != 0} {
						set errorstate 1
					}
				}
				fGetJob jobName
				set countertype "marking"
				fGetCounter $countertype batchcount
				set countertype ""
				fGetCounter $countertype totalcount
				set message "STS|$state|$errorstate|$jobName|$batchcount|$totalcount|"
			}
			gjn {
				# get current job
				set result [fGetJob jobName]
				if {$result == 0} {
					set message "JOB|$jobName|-|"
				} else {
					set message "ERR"
				}
			}
			gjl {
				# get all jobs
				fGetJobNames names
				set amount [llength [split $names "$::receiveDelimiter"]]
				set names [string map {$::receiveDelimiter |} $names]
				set message "JBL|$amount|$names|"
			}
			gjd {
				# get current job data
				set result [fGetVars "" names]
				set amount [llength [split $names "$::receiveDelimiter"]]
				set names [string map {$::receiveDelimiter |} $names]
				set message "JDL|$amount|$names|"
			}
			gtd {
				# get time and date
				fGetRTC currenttime
				set chr [split $currenttime ""]
				set message "TAD|[lindex $chr 8][lindex $chr 9]/[lindex $chr 5][lindex $chr 6]/[lindex $chr 0][lindex $chr 1][lindex $chr 2][lindex $chr 3] [lindex $chr 11][lindex $chr 12]:[lindex $chr 14][lindex $chr 15]:[lindex $chr 17][lindex $chr 18]|"
			}
			tad {
				# set time and date
				set chr [split [lindex $line 1] ""]
				set time "[lindex $chr 6][lindex $chr 7][lindex $chr 8][lindex $chr 9]-[lindex $chr 3][lindex $chr 4]-[lindex $chr 0][lindex $chr 1]T[lindex $chr 11][lindex $chr 12]:[lindex $chr 14][lindex $chr 15]:[lindex $chr 17][lindex $chr 18]$::receiveDelimiter"
				set result [fSetRTC $time]
				if {$result == 0} {
					set message "ACK"
				} else {
					set message "ERR"
				}
			}
			sst {
				# start stop the laser
				set state [lindex $line 1]
				if {$state == 3} {
					set result [fStart]
					if {$result == 0} {
						set message "ACK"
					} else {
						set message "ERR"
					}
				} elseif {$state == 4} {
					set result [fStop]
					if {$result == 0} {
						set message "ACK"
					} else {
						set message "ERR"
					}
				} else {
					set message "ERR"
				}
			}
			default {
				set message "ERR"
			}
		}
		# send answer to client
	cSend $client $message
	}
}

proc ZTCGetMessages {messages} {
	upvar $messages resultdata
	set result 0
	# get all not ACK messages
	set command "<Command Action=\"getsubtree\" Location=\"/Root/Lasers/Laser/Operation/ErrorMessages/ErrorMessage\[Acknowledged=&quot;false&quot;\]\[Class=&quot;W&quot;\]\"></Command>"
	StackCommand $command
	set result [SendCommandStack response]
	set ECount 0
	set WCount 0
	if {$result == 0} {
		set MsgText [regexp -all -inline "<MessageText>\(\[^<\]*\)</" $response]
		set ErrorCode [regexp -all -inline "<ErrorCode>\(\[^<\]*\)</" $response]
		set ErrorClass [regexp -all -inline "<Class>\(\[^<\]*\)</" $response]
		set WMessage ""
		set EMessage ""
		foreach MText $MsgText EClass $ErrorClass ECode $ErrorCode {
			if {[string length $MText] > 0} {
				if {$EClass == "W"} {
					# Warning
					append WMessage "$ECode|1|$MText|"
					incr WCount
				}
				if {$EClass == "E1" || $EClass == "E2"} {
					# Error that can be ACK
					append EMessage "$ECode|1|$MText|"
					incr ECount
				}
				if {$EClass == "F"} {
					# Fatal Error can not ACK
					append EMessage "$ECode|0|$MText|"
					incr ECount
				}
			}
		}
		set resultdata "$WCount|$WMessage^$ECount|$EMessage"
	} elseif {$result == 45023} {
		set resultdata "0|^0|"
	}
	return $WCount
}

# Read ExtensionSetup.txt file
if {[catch {set f [open "$argv/ExtensionSetup.txt" r]}] == 0} {
	set ZTCfileData [read $f]
	close $f
} else {
	set ZTCfileData ""
}
set ZTCfileLines [split $ZTCfileData "\n"]
foreach ZTCline $ZTCfileLines {
	set ZTClineElements [split $ZTCline ":"]
	set ZTCparameter [string tolower [lindex $ZTClineElements 0]]
	switch $ZTCparameter {
		active {
			set ZTCactive [lindex $ZTClineElements 1]
		}
		asyncstatus {
			set ZTCasyncStatus [lindex $ZTClineElements 1]
		}
		asyncjob {
			set ZTCasyncJob [lindex $ZTClineElements 1]
		}
		asyncprintcomplete {
			set ZTCasyncJob [lindex $ZTCasyncPrintComplete 1]
		}
		ztcport {
			set ZTCPort [lindex $ZTClineElements 1]
		}
		default {
			puts "failed to parse $ZTCline \"[lindex $ZTClineElements 0]\""
		}
	}
}
if {$ZTCactive == 1} {
	puts "Extension $extensionName with Version $extensionVersion is started"
	puts "listening on port: $ZTCPort"
	socket -server ZTCServerAccept $ZTCPort
}