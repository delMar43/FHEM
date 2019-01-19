##############################################################################
#
#     70_CanOverEthernet.pm
#
#     This file is part of Fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with Fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#
# CanOverEthernet (c) Martin Gutenbrunner / https://github.com/delmar43/FHEM
#
# This module is designed to work as a physical device in connection with 71_COE_Node
# as a logical device.
#
# Discussed in FHEM Forum: 
#
# $Id
#
##############################################################################
package main;

use strict;
use warnings;
use IO::Socket;
use DevIo;

sub CanOverEthernet_Initialize($) {
  my ($hash) = @_;

#  require "$attr{global}{modpath}/FHEM/DevIo.pm";
   
  $hash->{GetFn}     = "CanOverEthernet_Get";
  $hash->{SetFn}     = "CanOverEthernet_Set";
  $hash->{DefFn}     = "CanOverEthernet_Define";
  $hash->{UndefFn}   = "CanOverEthernet_Undef";
  $hash->{ReadFn}    = "CanOverEthernet_Read";

  $hash->{AttrList} = $readingFnAttributes;
  $hash->{MatchList} = { "1:COE_Node" => "^.*" };
  $hash->{Clients} = "COE_Node";

  Log3 '', 3, "CanOverEthernet - Initialize done ...";
}

sub CanOverEthernet_Define($$) {
  my ( $hash, $def ) = @_;
  my @a = split( "[ \t][ \t]*", $def );
 
  my $name   = $a[0];
  my $module = $a[1];
#  my $nodeId = $a[2];
 
  if(@a < 2 || @a > 2) {
     my $msg = "CanOverEthernet ($name) - Wrong syntax: define <name> CanOverEthernet";
     Log3 undef, 1, $msg;
     return $msg;
  }

#  $hash->{canNodeId} = $nodeId;

  DevIo_CloseDev($hash);

  $hash->{NAME} = $name;
  
  Log3 $name, 3, "CanOverEthernet ($name) - Define done ... module=$module";

  my $portno = 5441;
  my $conn = IO::Socket::INET->new(Proto=>"udp",LocalPort=>$portno);
 
  $hash->{FD}    = $conn->fileno();
  $hash->{CD}    = $conn;         # sysread / close won't work on fileno
  $selectlist{$name} = $hash;
 
  Log3 $name, 3, "CanOverEthernet ($name) - Awaiting UDP connections on port $portno\n";

  readingsSingleUpdate($hash, 'state', 'defined', 1);

  return undef;
}

sub CanOverEthernet_Undef($$) {
  my ($hash, $arg) = @_; 
  my $name = $hash->{NAME};

  DevIo_CloseDev($hash);

  return undef;
}

sub CanOverEthernet_Read($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $buf;
  my $data;

  $hash->{STATE} = 'Last: '.gmtime();
  $hash->{CD}->recv($buf, 16);
  $data = unpack('H*', $buf);
  Log3 $name, 3, "CanOverEthernet ($name) - Client said $data";

  Dispatch($hash, $buf);

}

sub CanOverEthernet_Get ($@) {
  my ( $hash, $param ) = @_;

  my $name = $hash->{NAME};
  Log3 $name, 3, "CanOverEthernet ($name) - Get done ...";
  return undef;
}

sub CanOverEthernet_Set ($@)
{
  my ( $hash, $param ) = @_;

  my $name = $hash->{NAME};
  Log3 $name, 3, "CanOverEthernet ($name) - Set done ...";
  return undef;
}

# Eval-Rückgabewert für erfolgreiches
# Laden des Moduls
1;


# Beginn der Commandref

=pod
=item [helper|device|command]
=item summary Kurzbeschreibung in Englisch was CanOverEthernet steuert/unterstützt
=item summary_DE Kurzbeschreibung in Deutsch was CanOverEthernet steuert/unterstützt

=begin html
 Englische Commandref in HTML
=end html

=begin html_DE
 Deustche Commandref in HTML
=end html

# Ende der Commandref
=cut
