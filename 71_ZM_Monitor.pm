package main;
use strict;
use warnings;
use FileHandle;

my @ZM_Functions = qw( None Monitor Modect Record Mocord Nodect );

sub ZM_Monitor_Initialize {
  my ($hash) = @_;

  $hash->{GetFn}       = "ZM_Monitor_Get";
  $hash->{SetFn}       = "ZM_Monitor_Set";
  $hash->{DefFn}       = "ZM_Monitor_Define";
  $hash->{UndefFn}     = "ZM_Monitor_Undef";
  $hash->{ReadFn}      = "ZM_Monitor_Read";
  $hash->{FW_detailFn} = "ZM_Monitor_DetailFn";
  $hash->{ParseFn}     = "ZM_Monitor_Parse";

  $hash->{AttrList} = "function enabled streamReplayBuffer ".$readingFnAttributes;
  $hash->{Match} = "^.*";

  

#  Log3 '', 3, "ZM_Monitor - Initialize done ...";

  return undef;
}

sub ZM_Monitor_Define {
  my ( $hash, $def ) = @_;
  my @a = split( "[ \t][ \t]*", $def );
 
  my $name   = $a[0];
  my $module = $a[1];
  my $zmMonitorId = $a[2];
  
  if(@a < 3 || @a > 3) {
     my $msg = "ZM_Monitor ($name) - Wrong syntax: define <name> ZM_Monitor <ZM_MONITOR_ID>";
     Log3 $name, 2, $msg;
     return $msg;
  }

  $hash->{NAME} = $name;
  readingsSingleUpdate($hash, "state", "idle", 1);

  AssignIoPort($hash);
  
  my $ioDevName = $hash->{IODev}{NAME};
  my $logDevAddress = $ioDevName.'_'.$zmMonitorId;
  # Adresse rückwärts dem Hash zuordnen (für ParseFn)
  $modules{ZM_Monitor}{defptr}{$logDevAddress} = $hash;
  
#  Log3 $name, 3, "ZM_Monitor ($name) - Define done ... module=$module, zmHost=$zmHost, zmMonitorId=$zmMonitorId";

  $hash->{helper}{ZM_MONITOR_ID} = $zmMonitorId;

  ZM_Monitor_UpdateStreamUrls($hash);

  return undef;
}

sub ZM_Monitor_UpdateStreamUrls {
  my ( $hash ) = @_;
  my $ioDevName = $hash->{IODev}{NAME};

  my $zmPathZms = $hash->{IODev}{helper}{ZM_PATH_ZMS};
  if (not $zmPathZms) {
    return undef;
  }

  my $zmHost = $hash->{IODev}{helper}{ZM_HOST};
  my $streamUrl = "http://$zmHost/";
  my $zmUsername = ZM_Monitor_Urlencode($hash->{IODev}{helper}{ZM_USERNAME});
  my $zmPassword = ZM_Monitor_Urlencode($hash->{IODev}{helper}{ZM_PASSWORD});
  my $authPart = "&user=$zmUsername&pass=$zmPassword";

  readingsBeginUpdate($hash);
  ZM_Monitor_WriteStreamUrlToReading($hash, $streamUrl, 'streamUrl', $authPart);

  my $pubStreamUrl = $attr{$ioDevName}{pubStreamUrl};
  if ($pubStreamUrl) {
    my $authHash = $hash->{IODev}{helper}{ZM_AUTH_KEY};
    if ($authHash) { #if ZM_AUTH_KEY is defeined, use the auth-hash. otherwise, use the previously defined username/pwd
      $authPart = "&auth=$authHash";
    }
    ZM_Monitor_WriteStreamUrlToReading($hash, $pubStreamUrl, 'pubStreamUrl', $authPart);
  }
  readingsEndUpdate($hash, 1);

  InternalTimer(gettimeofday() + 3600, "ZM_Monitor_UpdateStreamUrls", $hash);

  return undef;
}

sub ZM_Monitor_Urlencode {
    my $s = shift;
    $s =~ s/ /+/g;
    $s =~ s/([^A-Za-z0-9\+-])/sprintf("%%%02X", ord($1))/seg;
    return $s;
}

sub ZM_Monitor_WriteStreamUrlToReading {
  my ( $hash, $streamUrl, $readingName, $authPart ) = @_;

  my $zmPathZms = $hash->{IODev}{helper}{ZM_PATH_ZMS};
  my $zmMonitorId = $hash->{helper}{ZM_MONITOR_ID};
  $streamUrl = $streamUrl."/" if (not $streamUrl =~ m/\/$/);

  my $imageUrl = $streamUrl."$zmPathZms?mode=single&scale=100&monitor=$zmMonitorId".$authPart;
  my $imageReadingName = $readingName;
  $imageReadingName =~ s/Stream/Image/g;
  readingsBulkUpdate($hash, $imageReadingName, $imageUrl, 1);
  
  $streamUrl = $streamUrl."$zmPathZms?mode=jpeg&scale=100&maxfps=30&buffer=1000&monitor=$zmMonitorId".$authPart;
  readingsBulkUpdate($hash, $readingName, "$streamUrl", 1);
}

sub ZM_Monitor_DetailFn {
  my ( $FW_wname, $deviceName, $FW_room ) = @_;

  my $hash = $defs{$deviceName};
  my $streamDisabled = (ReadingsVal($deviceName, 'Function', 'None') eq 'None');
  if ($streamDisabled) {
    return '<div>Streaming disabled</div>';
  }

  ZM_Monitor_UpdateStreamUrls($hash);
  my $streamUrl = ReadingsVal($deviceName, 'pubStreamUrl', undef);
  if (not $streamUrl) {
    $streamUrl = ReadingsVal($deviceName, 'streamUrl', undef);
  }
  if ($streamUrl) {
    return "<div><img src='$streamUrl'></img></div>";
  } else {
    return undef;
  }
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

#  return "Unknown argument $opt, choose one of config";
  return undef;
}

sub ZM_Monitor_Set {
  my ( $hash, $name, $cmd, @args ) = @_;

  if ( "Function" eq $cmd ) {
    my $arg = $args[0];
    if (grep { $_ eq $arg } @ZM_Functions) {
#      Log3 $name, 0, "Function parameter: $arg";
      my $arguments = {
        method => 'changeMonitorFunction',
        zmMonitorId => $hash->{helper}{ZM_MONITOR_ID},
        zmFunction => $arg
      };
      my $result = IOWrite($hash, $arguments);
      return $result;
    }
    return "Unknown value $args[0] for $cmd, choose one of ".join(' ', @ZM_Functions);
  } elsif ("Enabled" eq $cmd ) {
    my $arg = $args[0];
    if ($arg eq '1' || $arg eq '0') {
      my $arguments = {
        method => 'changeMonitorEnabled',
        zmMonitorId => $hash->{helper}{ZM_MONITOR_ID},
        zmEnabled => $arg
      };
      my $result = IOWrite($hash, $arguments);
      return $result;
    }
    return "Unknown value $args[0] for $cmd, choose one of 0 1";
  }

#  return "Unknown argument $cmd, chose one of Function:None,Monitor,Modect,Record,Mocord,Nodect Enabled:0,1";
  return 'Function:'.join(',', @ZM_Functions).' Enabled:0,1';
}

# incoming messages from physical device module (70_ZoneMinder in this case).
sub ZM_Monitor_Parse {
  my ( $io_hash, $message) = @_;

  my @msg = split(/\:/, $message, 2);
  my $msgType = $msg[0];
  if ($msgType eq "event") {
    return ZM_Monitor_HandleEvent($io_hash, $msg[1]);
  } else {
    Log3 $io_hash, 0, "Unknown message type: $msgType";
  }

  return undef;
}

sub ZM_Monitor_HandleEvent {
  my ( $io_hash, $message ) = @_;

  my $ioName = $io_hash->{NAME};
  my @msgTokens = split(/\|/, $message);
  my $zmMonitorId = $msgTokens[0];
  my $alertState = $msgTokens[1];
  my $eventTs = $msgTokens[2];
  my $eventId = $msgTokens[3];

  my $logDevAddress = $ioName.'_'.$zmMonitorId;
  Log3 $io_hash, 5, "Handling event for logical device $logDevAddress";
  # wenn bereits eine Gerätedefinition existiert (via Definition Pointer aus Define-Funktion)
  if(my $hash = $modules{ZM_Monitor}{defptr}{$logDevAddress}) {
    Log3 $hash, 5, "Logical device $logDevAddress found. Writing readings";

    readingsBeginUpdate($hash);
    ZM_Monitor_createEventStreamUrl($hash, $eventId);
    my $state;
    if ($alertState eq "on") {
      $state = "alert";
#      ZM_Monitor_downloadEventImage($hash, $eventId);
    } elsif ($alertState eq "off") {
      $state = "idle";
    }
    readingsBulkUpdate($hash, "state", $state, 1);
    readingsBulkUpdate($hash, "alert", $alertState, 1);
    readingsBulkUpdate($hash, "lastEventTimestamp", $eventTs);
    readingsBulkUpdate($hash, "lastEventId", $eventId);
    readingsEndUpdate($hash, 1);

    Log3 $hash, 5, "Writing readings done. Now returning log dev name: $hash->{NAME}";
    # Rückgabe des Gerätenamens, für welches die Nachricht bestimmt ist.
    return $hash->{NAME};
  } else {
    # Keine Gerätedefinition verfügbar. Daher Vorschlag define-Befehl: <NAME> <MODULNAME> <ADDRESSE>
    my $autocreate = "UNDEFINED ZM_Monitor_$logDevAddress ZM_Monitor $zmMonitorId";
    Log3 $io_hash, 5, "logical device with address $logDevAddress not found. returning autocreate: $autocreate";
    return $autocreate;
  }
}

sub ZM_Monitor_downloadEventImage {
  my ( $hash, $eventId ) = @_;
  my $name = $hash->{NAME};
  
  my $zmPathZms = $hash->{IODev}{helper}{ZM_PATH_ZMS};
  if (not $zmPathZms) {
    return undef;
  }
  my $zmHost = $hash->{IODev}{helper}{ZM_HOST};
  my $zmUsername = ZM_Monitor_Urlencode($hash->{IODev}{helper}{ZM_USERNAME});
  my $zmPassword = ZM_Monitor_Urlencode($hash->{IODev}{helper}{ZM_PASSWORD});
  my $authPart = "&user=$zmUsername&pass=$zmPassword";
  my $zmMonitorId = $hash->{helper}{ZM_MONITOR_ID};
  my $streamUrl = "http://$zmHost/";
  my $imageUrl = $streamUrl."$zmPathZms?mode=single&scale=100&monitor=$zmMonitorId".$authPart;

  Log3 $name, 0, "ZM_Monitor ($name) - would download event image from $imageUrl";
  
  my $param = {
    url => $imageUrl,
    method => "GET",
    callback => \&ZM_Monitor_downloadEventImage_Callback,
    hash => $hash,
    eventId => $eventId
  };
  HttpUtils_NonblockingGet($param);
  
  return undef;
}

sub ZM_Monitor_downloadEventImage_Callback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $eventId = $param->{eventId};
  my $name = $hash->{NAME};

  if($err ne "") {
    Log3 $name, 3, "error while requesting ".$param->{url}." - $err";
#    readingsSingleUpdate($hash, "fullResponse", "ERROR", 0);
  } elsif($data ne "") {
    #Log3 $name, 3, "url ".$param->{url}." returned data";
    my $bin=pack("u", "$data");

    my $OUT= new FileHandle;
    open ($OUT, "/opt/fhem/unused/".$eventId.".jpg");
    print $OUT $bin;
    $OUT->close;
    
#    readingsSingleUpdate($hash, "fullResponse", $data, 0);
  }
}

#for now, this is nearly a duplicate of writing the streamUrl reading.
#will need some love to make better use of existing code.
sub ZM_Monitor_createEventStreamUrl {
  my ( $hash, $eventId ) = @_;
  my $ioDevName = $hash->{IODev}{NAME};

  my $zmPathZms = $hash->{IODev}{helper}{ZM_PATH_ZMS};
  if (not $zmPathZms) {
    return undef;
  }

  my $zmHost = $hash->{IODev}{helper}{ZM_HOST};
  my $streamUrl = "http://$zmHost/";
  my $zmUsername = ZM_Monitor_Urlencode($hash->{IODev}{helper}{ZM_USERNAME});
  my $zmPassword = ZM_Monitor_Urlencode($hash->{IODev}{helper}{ZM_PASSWORD});
  my $authPart = "&user=$zmUsername&pass=$zmPassword";
  ZM_Monitor_WriteEventStreamUrlToReading($hash, $streamUrl, 'eventStreamUrl', $authPart, $eventId);

  my $pubStreamUrl = $attr{$ioDevName}{pubStreamUrl};
  if ($pubStreamUrl) {
    my $authHash = $hash->{IODev}{helper}{ZM_AUTH_KEY};
    if ($authHash) { #if ZM_AUTH_KEY is defined, use the auth-hash. otherwise, use the previously defined username/pwd
      $authPart = "&auth=$authHash";
    }
    ZM_Monitor_WriteEventStreamUrlToReading($hash, $pubStreamUrl, 'pubEventStreamUrl', $authPart, $eventId);
  }
}

sub ZM_Monitor_WriteEventStreamUrlToReading {
  my ( $hash, $streamUrl, $readingName, $authPart, $eventId ) = @_;

  my $zmPathZms = $hash->{IODev}{helper}{ZM_PATH_ZMS};
  $streamUrl = $streamUrl."/" if (not $streamUrl =~ m/\/$/);

  my $zmMonitorId = $hash->{helper}{ZM_MONITOR_ID};
  my $imageUrl = $streamUrl."$zmPathZms?mode=single&scale=100&maxfps=30&buffer=1000&monitor=$zmMonitorId".$authPart;
  my $imageReadingName = $readingName;
  $imageReadingName =~ s/Stream/Image/g;
  readingsBulkUpdate($hash, $imageReadingName, $imageUrl, 1);

  $streamUrl = $streamUrl."$zmPathZms?source=event&mode=jpeg&event=$eventId&frame=1&scale=100&rate=100&maxfps=30&replay=gapless".$authPart;
  readingsBulkUpdate($hash, $readingName, $streamUrl, 1);

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
