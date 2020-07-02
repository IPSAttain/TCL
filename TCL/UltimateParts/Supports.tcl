package provide Supports 1.6

proc script {script} \
{ 
  set rc [catch { uplevel 1 $script } msg]
  if {$rc} { puts $msg } 
  return $rc
}

proc ConvertXPath {xpath} {
	return [string map {\" &quot;} $xpath]
}

proc GenerateUniqueID {} {
	return "a[::uuid::tostring [::uuid::generate_tcl]]"
}

proc lremove {args} {
	if {[llength $args] < 2} {
		puts stderr {Wrong # args: should be "lremove ?-all? list pattern"}
	}
	set list [lindex $args end-1]
	set elements [lindex $args end]
	if [string match -all [lindex $args 0]] {
		foreach element $elements {
			set list [lsearch -all -inline -not -exact $list $element]
		}
	} else {
		foreach element $elements {
			set idx [lsearch $list $element]
			set list [string trim \
				"[lreplace $list $idx end] [lreplace $list 0 $idx]"]
		}
	}
	return $list
}

proc GetStringBetween {exp startTag endTag lastIndex {beginIndex 0} {minLength 0}} {
	upvar 1 $exp expression 
	upvar 1 $lastIndex endIndex
	set endIndex -1
	#Debug "inGetStringBetween: $expression $startTag $endTag $lastIndex $beginIndex $minLength" 1
	set stringLength [string length $expression]
	if {[expr {$stringLength < $beginIndex}]} {
		return ""
	}

	set startIndex [string first $startTag $expression $beginIndex]
	if {[expr {$startIndex < 0}]} {
		return ""
	}

	set contentBeginIndex [expr {$startIndex + [string length $startTag]}]
	

	set contentEndIndex [string first $endTag $expression [expr {$contentBeginIndex+$minLength}]]
	if {[expr {$contentEndIndex < 0}]} {
		set contentEndIndex [string length $expression]
	}
	
	set endIndex [expr {$contentEndIndex + [string length $endTag]}]

	#Debug "returning: [string range $expression $contentBeginIndex [expr {$contentEndIndex - 1}]]" 1
	return [string range $expression $contentBeginIndex [expr {$contentEndIndex - 1}]]
}