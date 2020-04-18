##############################################
##############################################
# $Id: 98_SE_Modbus.pm 
#
#	fhem Modul für SE Devices
#	verwendet Modbus.pm als Basismodul für die eigentliche Implementation des Protokolls.
#
#	This file is part of fhem.
# 
#	Fhem is free software: you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation, either version 2 of the License, or
#	(at your option) any later version.
# 
#	Fhem is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
#	You should have received a copy of the GNU General Public License
#	along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#	Changelog:
#	2020-04-11	initial release



package main;

use strict;
use warnings;
use Time::HiRes qw( time );

sub SE_Modbus_Initialize($);
sub MinMaxChk($$$;$$);				# prüft, ob ein Wert außerhalb Min/Max ist

# deviceInfo defines properties of the device.
# some values can be overwritten in parseInfo, some defaults can even be overwritten by the user with attributes if a corresponding attribute is added to AttrList in _Initialize.
#
my %SE_deviceInfo = (
	"timing"	=>	{
			timeout		=>	2,		# 2 seconds timeout when waiting for a response
			commDelay	=>	0.7,	# 0.7 seconds minimal delay between two communications e.g. a read a the next write,
									# can be overwritten with attribute commDelay if added to AttrList in _Initialize below
			sendDelay	=>	0.7,	# 0.7 seconds minimal delay between two sends, can be overwritten with the attribute
									# sendDelay if added to AttrList in _Initialize function below
			}, 
	"h"			=>	{				# details for "holding registers" if the device offers them
			read		=>	3,		# use function code 3 to read registers
			write		=>	6,		# use function code 6 to write registers
			defPoll		=>	1,		# All defined Input Registers should be polled by default unless specified otherwise in parseInfo or by attributes
			defShowGet	=>	1,		# default für showget Key in parseInfo
			},
);

# %parseInfo:
# r/c/i+adress => objHashRef (h = holding register, c = coil, i = input register, d = discrete input)
# the address is a decimal number without leading 0
#
# Explanation of the parseInfo hash sub-keys:
# name			internal name of the value in the modbus documentation of the physical device
# reading		name of the reading to be used in Fhem
# set			can be set to 1 to allow writing this value with a Fhem set-command
# setmin		min value for input validation in a set command
# setmax		max value for input validation in a set command
# hint			string for fhemweb to create a selection or slider
# expr			perl expression to convert a string after it has bee read
# map			a map string to convert an value from the device to a more readable output string 
# 				or to convert a user input to the machine representation
#				e.g. "0:mittig, 1:oberhalb, 2:unterhalb"				
# setexpr		per expression to convert an input string to the machine format before writing
#				this is typically the reverse of the above expr
# format		a format string for sprintf to format a value read
# len			number of Registers this value spans
# poll			defines if this value is included in the read that the module does every defined interval
#				this can be changed by a user with an attribute
# unpack		defines the translation between data in the module and in the communication frame
#				see the documentation of the perl pack function for details.
#				example: "n" for an unsigned 16 bit value or "f>" for a float that is stored in two registers
# showget		can be set to 1 to allow a Fhem get command to read this value from the device
# polldelay		if a value should not be read in each iteration after interval has passed, 
#				this value can be set to a multiple of interval

my %SE_parseInfo = (



##############################################################################
# StateCode Register
##############################################################################

"h40107"	=>	{										# uint16; Active State Code
					name		=> "F_Active_State_Code",	# internal name of this register in the hardware doc
					reading		=> "ActiveStateCode",		# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "n",						# defines the translation between data in the module and in the communication frame
					map			=> "1:Off, 2:Sleeping (auto-shutdown) - Night Mode, 3:Grid Monitoring-Wake-Up, 4:On - SearchingMPPT, 5:Prouction, 6:Shutting down, 7:Error exists, 8:Maintenance setup",	# map to convert visible values to internal numbers (for reading and writing)
				},


##############################################################################
# Model Register
##############################################################################

"h40004"	=>	{											# String32; Manufacturer
					name		=> "Mn",					# internal name of this register in the hardware doc
					reading		=> "Manufacturer",			# name of the reading for this value
					len			=> 16,						# number of Registers this value spans
					unpack		=> "A*",					# defines the translation between data in the module and in the communication frame
					poll		=> "once",					# only poll once after define (or after a set)
				},

"h40020"	=>	{											# String32; Device model
					name		=> "Md",					# internal name of this register in the hardware doc
					reading		=> "Device_model",			# name of the reading for this value
					len			=> 16,						# number of Registers this value spans
					unpack		=> "A*",					# defines the translation between data in the module and in the communication frame
					poll		=> "once",					# only poll once after define (or after a set)
				},


"h40044"	=>	{											# String16; SW version of inverter
					name		=> "Vr",					# internal name of this register in the hardware doc
					reading		=> "SW_Version_Inverter",	# name of the reading for this value
					len			=> 8,						# number of Registers this value spans
					unpack		=> "A*",					# defines the translation between data in the module and in the communication frame
					#poll		=> "once",
					polldelay	=> "x200",
					expr		=> '$val =~ s/^0+//gr'		
				},

"h40052"	=>	{											# String32; Serialnumber of the inverter
					name		=> "SN",					# internal name of this register in the hardware doc
					reading		=> "Serialnumber",			# name of the reading for this value
					len			=> 16,						# number of Registers this value spans
					unpack		=> "A*",					# defines the translation between data in the module and in the communication frame
					#poll		=> "once",
					polldelay	=> "x200",
							
				},

"h40068"	=>	{											# uint16; Modbus Device Address
					name		=> "DA",					# internal name of this register in the hardware doc
					reading		=> "Modbus_Address",		# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "n",						# defines the translation between data in the module and in the communication frame
					poll		=> "once",					# only poll once after define (or after a set)
					set			=> 1,						# can be set to 1 to allow writing this value with a Fhem set-command
					min			=> 1,						# input validation for set: min value
					max			=> 247,						# input validation for set: max value
				},

"h40069"	=>	{											# uint16; Uniquely identifies this as a SunSpec Inverter Modbus Map
					name		=> "ID",					# internal name of this register in the hardware doc
					reading		=> "Inverter_map",			# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "n",						# defines the translation between data in the module and in the communication frame
					map			=> "101:single.phase, 102:split.phase, 103:three.phase",	# map to convert visible values to internal numbers (for reading and writing)
					poll		=> "once",					# only poll once after define (or after a set)
				},

##############################################################################
# String Register
##############################################################################
"h40096"	=>	{	
					name		=> "I_DC_Current",			# internal name of this register in the hardware doc
					reading		=> "DC_current_A",			# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "s>",					# defines the translation between data in the module and in the communication frame
					expr		=> '$val *10** (ReadingsVal("$name","SF_DC_current_A",0))',			# conversion of raw value to visible value 
					format		=> '%.2f',					# format string for sprintf
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
				},
				
"h40097"	=>	{	
					name		=> "I_DC_Current_SF",		# internal name of this register in the hardware doc
					reading		=> "SF_DC_current_A",		# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "n!",					# defines the translation between data in the module and in the communication frame
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
				},				
				
				
				
				
				
"h40098"	=>	{	
					name		=> "I_DC_Voltage",			# internal name of this register in the hardware doc
					reading		=> "DC_current_V",			# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "s>",					# defines the translation between data in the module and in the communication frame
					expr		=> '$val *10** (ReadingsVal("$name","SF_DC_current_V",0))',			# conversion of raw value to visible value 
					format		=> '%.1f',					# format string for sprintf
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
				},
"h40099"	=>	{	
					name		=> "I_DC_Voltage_SF",		# internal name of this register in the hardware doc
					reading		=> "SF_DC_current_V",		# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "n!",					# defines the translation between data in the module and in the communication frame
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
				},
				
				
				
				
				
				
"h40100"	=>	{
					name		=> "I_DC_Power",					# internal name of this register in the hardware doc
					reading		=> "DC_current_W",		# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "s>",					# defines the translation between data in the module and in the communication frame
					expr		=> '$val *10** (ReadingsVal("$name","SF_DC_current_W",0))',			# conversion of raw value to visible value 
					format		=> '%.1f',					# format string for sprintf
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
				},
"h40101"	=>	{	
					name		=> "I_DC_Power_SF",					# internal name of this register in the hardware doc
					reading		=> "SF_DC_current_W",		# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "n!",					# defines the translation between data in the module and in the communication frame
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
				},



##############################################################################
# Temp Register
##############################################################################

"h40103"	=>	{	
					name		=> "I_Temp_Sink",					# internal name of this register in the hardware doc
					reading		=> "Heat_Sink_Temperature",		# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "s>",					# defines the translation between data in the module and in the communication frame
					expr		=> '$val *10** (ReadingsVal("$name","SF_Heat_Sink_Temperature",0))',  #conversion of raw value to visible value 
					format		=> '%.2f',					# format string for sprintf
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
				},	
"h40106"	=>	{	
					name		=> "I_Temp_SF",					# internal name of this register in the hardware doc
					reading		=> "SF_Heat_Sink_Temperature",		# name of the reading for this value
					len			=> 1,						# number of Registers this value spans
					unpack		=> "n!",					# defines the translation between data in the module and in the communication frame
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
				},					
				
				
##############################################################################
# production Register
##############################################################################
				
"h40093" => {    # 40094 (Len 3) 40094 to 40096 AC Lifetime Energy production
					name		=> "I_AC_Energy_WH",					# internal name of this register in the hardware doc
					reading		=> "AC_Lifetime_Energy_production_kWh",		# name of the reading for this value
					len			=> 3,						# number of Registers this value spans
					unpack		=> "l>s>",					# defines the translation between data in the module and in the communication frame
					format		=> '%.2f',
					polldelay	=> "x1",					# only poll this Value if last read is older than 3*Iteration, otherwiese getUpdate will skip it
					expr    	=> '$val /1000',






       # 'len'     => '3',                                                               #I_AC_Energy_WH (2), I_AC_Energy_WH_SF
        #'reading' => 'Block_AC_Energy_WH',
        #'unpack'  => 'l>s>',
        #'expr'    => 'ExprMppt($hash,$name,"I_AC_Energy_WH",$val[0],$val[1],0,0,0)',    # conversion of raw value to visible value
    },				
# Ende parseInfo
);


#####################################
sub SE_Modbus_Initialize($) {
    my ($modHash) = @_;

	require "$attr{global}{modpath}/FHEM/98_Modbus.pm";

	$modHash->{parseInfo}  = \%SE_parseInfo;			# defines registers, inputs, coils etc. for this Modbus Defive

	$modHash->{deviceInfo} = \%SE_deviceInfo;			# defines properties of the device like 
															# defaults and supported function codes

	ModbusLD_Initialize($modHash);							# Generic function of the Modbus module does the rest

	$modHash->{AttrList} = $modHash->{AttrList} . " " .		# Standard Attributes like IODEv etc 
		$modHash->{ObjAttrList} . " " .						# Attributes to add or overwrite parseInfo definitions
		$modHash->{DevAttrList} . " " .						# Attributes to add or overwrite devInfo definitions
		"poll-.* " .										# overwrite poll with poll-ReadingName
		"polldelay-.* ";									# overwrite polldelay with polldelay-ReadingName
}

sub MinMaxChk($$$;$$) {										# prüft, ob ein Wert außerhalb Min/Max ist
	my $Zahl	= $_[0];									# Übergabe des zu prüfenden Wertes
	my $Min		= $_[1];									# Übergabe Minimum
	my $Max		= $_[2];									# Übergabe Maximum
	;
	my $name	= $_[3];									# optional: Übergabe Name vom Device
	my $Reading	= $_[4];									# optional: Übergabe Name Reading (für Auslesen letzten Wert)

	if (defined $Reading) {									# wenn Name Reading  übergeben wurde
		if ($Zahl < $Min) {									# Zahl ist kleiner als Minimum
			$Zahl = ReadingsNum($name,$Reading,$Min);		# Zahl auf letzten Wert setzen
		}
		if ($Zahl > $Max) {									# Zahl ist größer als Maximum
			$Zahl = ReadingsNum($name,$Reading,$Max);		# Zahl auf letzten Wert setzen
		}
	} else {												# wenn Name Reading  nicht übergeben wurde
		if ($Zahl < $Min) {									# Zahl ist kleiner als Minimum
			$Zahl = $Min;									# Zahl auf Minimum setzen
		}
		if ($Zahl > $Max) {									# Zahl ist größer als Maximum
			$Zahl = $Max;									# Zahl auf Maximum setzen
		}
	}


	return $Zahl;
}


1;

