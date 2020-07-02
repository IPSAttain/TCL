#! /bin/sh
	
#****************************************************************************
#
# Alltec-Lasersystems ACC2/ACC3/IceMark/CMark
#
# This shell-script will be executed from the AOS during the Laser Startup 
# process and invoke the applications listed below.
#
# To use the settings in this file, you will have to uncomment them,
# as well as change the name of the application that should be started.
#
#****************************************************************************	

# add tclsh path for QMark and IceMark
export PATH=$PATH:/usr/local/bin

# add tclsh path for CMark
export PATH=$PATH:/usr/bin

# tcl file locations
tclLocations="/mnt/flash/smarties/customer /mnt/flash/smarties/customer/tcl /smarties/customer /smarties/customer/tcl"

## starting a TCL script:
## 1. wait until the script has finished
#TCLscript.tcl
## 2. don't wait for the script to finish
#TCLscript.tcl &

echo "Starting Ultimate"

if [ -f "/usr/local/bin/tclsh8.4" ];
then
	for i in $tclLocations; do
		if [ -f $i/Starter.tcl ];
		then 
			tclsh8.4 $i/Starter.tcl $i &> $i/Start.log &
			exit 1
		fi
	done
fi
if [ -f "/usr/bin/tclsh8.5" ];
then
	for i in $tclLocations; do
		if [ -f $i/Starter.tcl ];
		then 
			tclsh8.5 $i/Starter.tcl $i &> $i/Start.log &
			exit 1
		fi
	done
fi
if [ -f "/usr/bin/tclsh" ];
then
	for i in $tclLocations; do
		if [ -f $i/Starter.tcl ];
		then 
			tclsh $i/Starter.tcl $i &> $i/Start.log &
			exit 1
		fi
	done
	#tclsh $SCRIPTPATH/Starter.tcl > $SCRIPTPATH/Start.log &
	#exit 1
fi

echo "TCL Interpreter Path not found on startup.sh"

