lappend auto_path [file dirname [info script]]

#AR19.07.2018
#changed text file parser to allow platform independent linefeed separated files without error messages

# General Setup
set active 1

# Interface Setup
# tcp rs232
set interface tcp
set tcpListenPort 20001
set ttyMode {9600,n,8,1}
set ttyHandshake {none}

set killPort 19999

# Communication Setup
set receiveDelimiter ";"
set sendDelimiter ";"
set sendAnswer 1

# Debug Setup
set debugPort 20002
set debugLevel 1

# Push Messages
set asyncPort 20003
set pushStateChange 0
set pushTemplateChange 0
set pushMarkingCounterChange 0
set pushProductCounterChange 0
set pushMarkResult 0

# Extension Setup
set useLegacyExtensionPackage 0

# Laser Setup
set laserType "unknown"

# Read Setup
if {[catch {set f [open "$argv/Setup.txt" r]}] == 0} {
	set fileData [read $f]
	close $f
} else {
	set fileData ""
}

set fileLines [split $fileData "\n"]
foreach line $fileLines {
	set lineElements [split [string trim $line] ":"]	
	for {set i [expr {[llength $lineElements]-1}]} {$i >= 0} {incr i -1} {
		set newval [string trim [lindex $lineElements $i]]
		set lineElements [lreplace $lineElements[set lineElements {}] $i $i $newval]
	}	
	set parameter [string tolower [lindex $lineElements 0]]
	switch $parameter {
		active {
			set active [lindex $lineElements 1]
		}
		interface {
			set interface [lindex $lineElements 1]
		}
		tcplistenport {
			set tcpListenPort [lindex $lineElements 1]
		}
		ttymode {
			set ttyMode [lindex $lineElements 1]
		}
		ttyhandshake {
			set ttyHandshake [lindex $lineElements 1]
		}
		receivedelimiter {
			set receiveDelimiter [lindex $lineElements 1]
		}
		senddelimiter {
			set sendDelimiter [lindex $lineElements 1]
		}
		sendanswer {
			set sendAnswer [lindex $lineElements 1]
		}
		debugport {
			set debugPort [lindex $lineElements 1]
		}
		debuglevel {
			set debugLevel [lindex $lineElements 1]
		}
		asyncport {
			set asyncPort [lindex $lineElements 1]
		}
		pushstatechange {
			set pushStateChange [lindex $lineElements 1]
		}
		pushtemplatechange {
			set pushTemplateChange [lindex $lineElements 1]
		}
		pushmarkingcounterchange {
			set pushMarkingCounterChange [lindex $lineElements 1]
		}
		pushproductcounterchange {
			set pushProductCounterChange [lindex $lineElements 1]
		}
		pushmarkresult {
			set pushMarkResult [lindex $lineElements 1]
		}
		default {
			if {[string length $parameter] > 0} {
				puts "failed to parse $line \"[lindex $lineElements 0]\""
			}
		}
	}
}

# Version Information
proc ParseStarter {command values responseData} {
	upvar $responseData resultdata
	set result 0
	
	switch $command {
		getversion {
			set result [ReadVersion resultdata]
		}
		default {
			set result -2
		}
	}
	
	return $result
}

proc ReadVersion {version} {
	upvar $version versionData
	set versionData "Ultimate[package versions Ultimate].$::revision$::sendDelimiter"
	if {[info exists ::extensionName] && [info exists ::extensionVersion]} {
		append versionData "Extension$::extensionName$::extensionVersion"
	} else {
		append versionData "UnknownExtension"
	}
	
	return 0
}

# Load Packages

if {[catch {source $argv/SPEU3Extension.tcl}]} {
	if {[catch {source $argv/Extension.tcl} msg]} {
		puts "Failed to load Extension.tcl - error: $msg"
		package require ExtensionDefault
	}
} else {
	set useLegacyExtensionPackage 1
}

package require Debug
package require Supports
package require XMLConstants
package require XMLCommunication
package require uuid
package require Ultimate

Debug "Packages loaded" 1

if {$active == 1} {
	# Start XML Interface
	set interfaceStatus [StartInterface]

	# Read OS Type
	if {[catch {set f [open "/mnt/flash/smarties/version.txt" r]}] == 0} {
		# QMark or IceMark
		set fileData [read $f]
		close $f
	} elseif {[catch {set f [open "/smarties/version.txt" r]}] == 0} {
		# CMark
		set fileData [read $f]
		close $f
	} else {
		# Unknown
		set fileData ""
	}

	set fileLines [split $fileData "\n"]
	foreach line $fileLines {
		if {[string first "QMark" $line] >= 0} {
			set laserType "qmark"
			break
		} elseif {[string first "IceMark" $line] >= 0} {
			set laserType "icemark"
			break
		} elseif {[string first "CMark" $line] >= 0} {
			set laserType "cmark"
			break
		}
	}

	Debug "laserType is $laserType" 1

	socket -server cServerAcceptKill $killPort
	
	# Block further actions on Legacy Extension
	if {$useLegacyExtensionPackage} {
		Debug "Using Legacy Extension" 1
		vwait forever
	}

	# Start Customer Interface
	if {$interface == "tcp"} {
		socket -server cServerAccept $tcpListenPort
		if {$tcpListenPort != $asyncPort} {
			socket -server cServerAcceptAsync $asyncPort
		}
		Debug "Interface TCP started" 1
	} elseif {$interface == "rs232"} {
		
		if {$laserType == "icemark"} {
			set ttyDevice {/dev/ttyS0}
		} else {
			set ttyDevice {/dev/ttyS1}
		}
		
		set tty [open $ttyDevice RDWR]
		
		fconfigure $tty -mode $ttyMode -buffering line -translation crlf -handshake $ttyHandshake -encoding utf-8
		fileevent $tty readable "cInputEvent $tty"
		Debug "Interface RS232 Started" 1
	} else {
		Debug "Selected Interface Invalid" 1
	}

	vwait forever
}

Debug "End Ultimate" 1