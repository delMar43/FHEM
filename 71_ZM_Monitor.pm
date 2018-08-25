package main;
use strict;
use warnings;

sub ZM_Monitor_Initialize {
  my ($hash) = @_;

  $hash->{GetFn}       = "ZM_Monitor_Get";
  $hash->{SetFn}       = "ZM_Monitor_Set";
  $hash->{DefFn}       = "ZM_Monitor_Define";
  $hash->{UndefFn}     = "ZM_Monitor_Undef";
  $hash->{ReadFn}      = "ZM_Monitor_Read";
  $hash->{FW_detailFn} = "ZM_Monitor_DetailFn";
  $hash->{ParseFn}     = "ZM_Monitor_Parse";

  $hash->{AttrList} = "streamUrl " . $readingFnAttributes;

  $hash->{Match} = "^.*";

#  Log3 '', 3, "ZM_Monitor - Initialize done ...";

  return undef;
}

sub ZM_Monitor_Define {
  my ( $hash, $def ) = @_;
  my @a = split( "[ \t][ \t]*", $def );
 
  my $name   = $a[0];
  my $module = $a[1];
  my $zmHost = $a[2];
  my $zmMonitorId = $a[3];
  
  if(@a < 4 || @a > 4) {
     my $msg = "ZM_Monitor ($name) - Wrong syntax: define <name> ZM_Monitor <ZM_URL> <ZM_MONITOR_ID>";
     Log3 $name, 2, $msg;
     return $msg;
  }

  $hash->{NAME} = $name;
  readingsSingleUpdate($hash, "state", "idle", 1);

  # Adresse rückwärts dem Hash zuordnen (für ParseFn)
  $modules{ZM_Monitor}{defptr}{$zmMonitorId} = $hash;
  
#  Log3 $name, 3, "ZM_Monitor ($name) - Define done ... module=$module, zmHost=$zmHost, zmMonitorId=$zmMonitorId";

  $hash->{helper}{ZM_HOST} = $zmHost;
  $hash->{helper}{ZM_MONITOR_ID} = $zmMonitorId;

  AssignIoPort($hash);

  my $ioDevName = $hash->{IODev}{helper}{ZM_HOST};
  Log3 $name, 0, "ZM_Monitor ($name) - ioDevice:$ioDevName";

#  ZM_Monitor_API_ReadMonitorConfig($hash);

  return undef;
}

sub ZM_Monitor_API_ReadMonitorConfig {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $zmMonitorId = $hash->{helper}{ZM_MONITOR_ID};
  
  my $arguments = {
    method => "monitors",
    parameter => "5"
  };
  IOWrite($hash, $arguments);
}

sub ZM_Monitor_DetailFn {
  my ( $FW_wname, $deviceName, $FW_room ) = @_;
  
  Log3 "ZM_Monitor", 3,  "ZM_Monitor  $FW_wname, $deviceName, $FW_room\n";
  my $hash = $defs{$deviceName};
  my $streamUrl = $attr{$deviceName}{streamUrl};

  my $zmHost = $hash->{IODev}{helper}{ZM_HOST};

  $streamUrl = "http://$zmHost/" if (not $streamUrl);
  $streamUrl = $streamUrl."/" if (not $streamUrl =~ m/\/$/);

  my $authHash = $hash->{IODev}{helper}{ZM_AUTH_KEY};
  my $zmPathZms = $hash->{IODev}{helper}{ZM_PATH_ZMS};
  my $zmMonitorId = $hash->{helper}{ZM_MONITOR_ID};
  $streamUrl = $streamUrl."$zmPathZms?mode=jpeg&scale=100&maxfps=30&buffer=1000&monitor=$zmMonitorId&auth=$authHash";

  return "<div><img src='$streamUrl'></img></div>";
}

sub ZM_Monitor_Undef {
  my ($hash, $arg) = @_; 
  my $name = $hash->{NAME};

  return undef;
}

sub ZM_Monitor_Read {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  return undef;
}

sub ZM_Monitor_Get {
  my ( $hash, $name, $opt, @args ) = @_;

#  my $name = $hash->{NAME};
  Log3 $name, 3, "ZM_Monitor ($name) - name:$name opt:$opt";
  if ($opt eq "config") {
    my $arguments = {
      method => "monitors",
      parameter => $hash->{helper}{ZM_MONITOR_ID}
    };
    my $result = IOWrite($hash, $arguments);
    ZM_Monitor_HandleMonitors();
  }

#  return "Unknown argument $opt, choose one of config";
  return undef;
}

sub ZM_Monitor_Set {
  my ( $hash, $param ) = @_;

  my $name = $hash->{NAME};
#  Log3 $name, 3, "ZM_Monitor ($name) - Set done ...";

#  return "Unknown argument $opt, chose one of Function Enabled";
  return undef;
}

sub ZM_Monitor_Parse {
  my ( $io_hash, $message) = @_;

  my @msg = split(/\:/, $message, 2);
  my $msgType = $msg[0];
  if ($msgType eq "event") {
    return ZM_Monitor_HandleEvent($io_hash, $msg[1]);
  } elsif ($msgType eq "monitors") {
    return ZM_Monitor_HandleMonitors($io_hash, $msg[1]);
  } else {
    Log3 $io_hash, 0, "Unknown message type: $msgType";
  }

  return undef;
}

sub ZM_Monitor_HandleEvent {
  my ( $io_hash, $message ) = @_;

  my @msgTokens = split(/\|/, $message);
  my $address = $msgTokens[0];
#  Log3 $io_hash, 3, "ZM_Monitor - ParseFn Address = $address";
  my $alertState = $msgTokens[1];
  my $eventTs = $msgTokens[2];
  my $eventId = $msgTokens[3];

  # wenn bereits eine Gerätedefinition existiert (via Definition Pointer aus Define-Funktion)
  if(my $hash = $modules{ZM_Monitor}{defptr}{$address}) {
    my $state;
    if ($alertState eq "on") {
      $state = "alert";
    } elsif ($alertState eq "off") {
      $state = "idle";
    }
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "state", $state, 1);
    readingsBulkUpdate($hash, "alert", $alertState, 1);
    readingsBulkUpdate($hash, "lastEventTimestamp", $eventTs);
    readingsBulkUpdate($hash, "lastEventId", $eventId);
    readingsEndUpdate($hash, 1);

    # Rückgabe des Gerätenamens, für welches die Nachricht bestimmt ist.
    return $hash->{NAME};
  } else {
    # Keine Gerätedefinition verfügbar
    # Daher Vorschlag define-Befehl: <NAME> <MODULNAME> <ADDRESSE>
    my $zmHost = $io_hash->{DEF};
    my $autocreate = "UNDEFINED ZM_Monitor_$io_hash->{NAME}_$address ZM_Monitor $zmHost $address";
    return $autocreate;
  }
}

sub ZM_Monitor_HandleMonitors {
  my ( $io_hash, $message ) = @_;
  Log3 "ZM_Monitor", 1, "HandleMonitors. message: $message";

  my $arguments = {
    method => "GetConfigValueByKey",
    parameter => "Id",
    data => $message
  };
  my $zmMonitorId = IOWrite($io_hash, $arguments);
  my $hash = $modules{ZM_Monitor}{defptr}{$zmMonitorId};
  
  my $function;
  my $enabled;
  my $streamReplayBuffer;

  return undef;
}

# Eval-Rückgabewert für erfolgreiches
# Laden des Moduls
1;


# Beginn der Commandref

=pod
=item [helper|device|command]
=item summary Kurzbeschreibung in Englisch was ZoneMinder steuert/unterstützt
=item summary_DE Kurzbeschreibung in Deutsch was ZoneMinder steuert/unterstützt

=begin html
 Englische Commandref in HTML
=end html

=begin html_DE
 Deustche Commandref in HTML
=end html

# Ende der Commandref
=cut
