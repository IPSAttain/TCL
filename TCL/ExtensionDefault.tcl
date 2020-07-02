package provide ExtensionDefault 1.6
#Extension for Ultimate 1.6

set extensionVersion 1.6
set extensionName "Default"

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
	
}

proc ActualStateChangedExtension {newState} {
	
}

proc ProductCounterValueChangedExtension {} {
	
}

proc MarkingCounterValueChangedExtension {} {
	
}

#Customer Specific Procedures
