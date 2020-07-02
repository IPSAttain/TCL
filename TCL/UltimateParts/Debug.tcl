lappend auto_path [file dirname [info script]]
package provide Debug 1.6.7

#AR 19.07.2018
#set socket to non-blocking and added catch-block for disconnect (TCL-79)


set debugChannel 0
set msStart 0

proc DebugServerAccept {client addr port} {

	if {$::debugChannel != 0} {
		Debug "Disconnecting debug client: $::debugChannel" 1
		script {close $::debugChannel}
		set ::debugChannel 0
	}
	set ::debugChannel $client
	Debug "Debug client connected: $::debugChannel" 1
	
	fconfigure $::debugChannel -buffering line -translation crlf -blocking 0 -encoding utf-8
	fileevent $::debugChannel readable "DebugServerInputEvent"
}

proc DebugServerInputEvent {} {
	if {$::debugChannel != 0} {
		gets $::debugChannel debugData
		
		if {[eof $::debugChannel]} {
			Debug "Debug client disconnected: $::debugChannel" 1
			script {close $::debugChannel}
			set ::debugChannel 0
		} else {
			set debugData [encoding convertfrom utf-8 $debugData]
			
			switch -regexp $debugData {
				setdebuglevel {
					set result 80002
					if {[regexp "^setdebuglevel;(\[0-9\]+);" $debugData all newlevel]} {
						if {[expr 1 <= $::debugLevel]} {
							puts "+++ DEBUG (Client) Set DebugLevel to $newlevel"
						}
						set ::debugLevel $newlevel
						set result 0
					}
					
					script { puts $::debugChannel "Set debuglevel result $result"; flush $::debugChannel }
				}
				getdebuglevel {
					script { puts $::debugChannel "debuglevel is $::debugLevel"; flush $::debugChannel }
				}
				default {
					if {[expr 1 <= $::debugLevel]} {
						puts "+++ DEBUG (Client) $debugData"
					}
				}
			}
		}
	}
}

proc Debug {text level} {
	DebugExtension $text $level
	if {[expr $level <= $::debugLevel]} {
		set t [clock clicks -milliseconds]
		set timestamp [format "%s.%03d" [clock format [expr {$t / 1000}] -format "%Y-%m-%d %H:%M:%S"] [expr {$t % 1000}]] 		
		if {$::debugChannel != 0} {
			set rc [script { puts $::debugChannel "$timestamp | $text"; flush $::debugChannel }]
			if {$rc} {
				puts "+++ DEBUG ($level) | $timestamp | Debug client \"$::debugChannel\" removed due to socket error"
				script {close $::debugChannel}
				set ::debugChannel 0
			}
		} 
		if {$::debugChannel == 0 || $level <= 1} {			
			puts "+++ DEBUG ($level) | $timestamp | $text"
		}
	}
}

proc DebugStartTime {} {
	if {[expr 4 <= $::debugLevel]} {
		set ::msStart [clock clicks -milliseconds]
	}
}

proc DebugEndTime {procName} {
	if {[expr 4 <= $::debugLevel]} {
		Debug "Elapsed Time for $procName = [expr [clock clicks -milliseconds] - $::msStart]" 4
	}
}

socket -server DebugServerAccept $debugPort