package main;
use strict;
use warnings;
use HttpUtils;

sub TA_CMI_JSON_Initialize;
sub TA_CMI_JSON_Define;
sub TA_CMI_JSON_GetStatus;
sub TA_CMI_JSON_Undef;
sub TA_CMI_JSON_PerformHttpRequest;
sub TA_CMI_JSON_ParseHttpResponse;
sub TA_CMI_JSON_Get;
sub TA_CMI_JSON_extractDeviceName;
sub TA_CMI_JSON_extractVersion;

sub TA_CMI_JSON_Initialize($) {
  my ($hash) = @_;

  $hash->{GetFn}     = "TA_CMI_JSON_Get";
  $hash->{DefFn}     = "TA_CMI_JSON_Define";
  $hash->{UndefFn}   = "TA_CMI_JSON_Undef";

  $hash->{AttrList} = "readingNamesInputs readingNamesOutputs readingNamesDL-Bus " . $readingFnAttributes;

  Log3 '', 3, "TA_CMI_JSON - Initialize done ...";
}

sub TA_CMI_JSON_Define($$) {
  my ( $hash, $def ) = @_;
  my @a = split( "[ \t][ \t]*", $def );
 
  my $name   = $a[0];
  my $module = $a[1];
  my $cmiUrl = $a[2];
  my $nodeId = $a[3];
  my $queryParams = $a[4];
 
  if(@a != 5) {
     my $msg = "TA_CMI_JSON ($name) - Wrong syntax: define <name> TA_CMI_JSON CMI-URL CAN-Node-ID QueryParameters";
     Log3 undef, 2, $msg;
     return $msg;
  }

  $hash->{NAME} = $name;
  $hash->{CMIURL} = $cmiUrl;
  $hash->{NODEID} = $nodeId;
  $hash->{QUERYPARAM} = $queryParams;
  $hash->{INTERVAL} = AttrVal( $name, "interval", "70" );
  
  Log3 $name, 5, "TA_CMI_JSON ($name) - Define done ... module=$module, CMI-URL=$cmiUrl, nodeId=$nodeId, queryParams=$queryParams";

  readingsSingleUpdate($hash, 'state', 'defined', 1);

  TA_CMI_JSON_GetStatus( $hash, 2 );

  return undef;
}

sub TA_CMI_JSON_GetStatus( $;$ ) {
  my ( $hash, $delay ) = @_;
  my $name = $hash->{NAME};

  TA_CMI_JSON_PerformHttpRequest($hash);
}

sub TA_CMI_JSON_Undef($$) {
  my ($hash, $arg) = @_; 
  my $name = $hash->{NAME};

  HttpUtils_Close($hash);

  return undef;
}

sub TA_CMI_JSON_PerformHttpRequest($) {
    my ($hash, $def) = @_;
    my $name = $hash->{NAME};
    my $url = "http://$hash->{CMIURL}/INCLUDE/api.cgi?jsonnode=$hash->{NODEID}&jsonparam=$hash->{QUERYPARAM}";

    my $param = {
                    url        => "$url",
                    timeout    => 5,
                    hash       => $hash,                                                                                 # Muss gesetzt werden, damit die Callback funktion wieder $hash hat
                    method     => "GET",                                                                                 # Lesen von Inhalten
                    header     => "User-Agent: TeleHeater/2.2.3\r\nAccept: application/json",                            # Den Header gemäß abzufragender Daten ändern
                    user       => "admin",
                    pwd        => "admin",
                    callback   => \&TA_CMI_JSON_ParseHttpResponse                                                                  # Diese Funktion soll das Ergebnis dieser HTTP Anfrage bearbeiten
                };

    HttpUtils_NonblockingGet($param);
}

sub TA_CMI_JSON_ParseHttpResponse($) {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $return;

  if($err ne "") {
     Log3 $name, 0, "error while requesting ".$param->{url}." - $err";                                               # Eintrag fürs Log
#     readingsSingleUpdate($hash, "fullResponse", "ERROR", 0);                                                        # Readings erzeugen
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, 'state', 'ERROR', 0);
      readingsBulkUpdate($hash, 'error', $err, 0);
      readingsEndUpdate($hash, 0);      
  } elsif($data ne "") {
     my $keyValues = json2nameValue($data);

     $hash->{STATE} = $keyValues->{Status};
     $hash->{CAN_DEVICE} = TA_CMI_JSON_extractDeviceName($keyValues->{Header_Device});
     $hash->{CMI_API_VERSION} = TA_CMI_JSON_extractVersion($keyValues->{Header_Version});

     readingsBeginUpdate($hash);
     readingsBulkUpdateIfChanged($hash, 'state', $keyValues->{Status});
     if ( $keyValues->{Status} eq 'OK' ) {
       my $queryParams = $hash->{QUERYPARAM};
       TA_CMI_JSON_extractReadings($hash, $keyValues, 'Inputs') if ($queryParams =~ /I/);
       TA_CMI_JSON_extractReadings($hash, $keyValues, 'Outputs') if ($queryParams =~ /O/);
       TA_CMI_JSON_extractReadings($hash, $keyValues, 'DL-Bus') if ($queryParams =~ /D/);
     }
     
     readingsEndUpdate($hash, 1);

#     Log3 $name, 3, "TA_CMI_JSON ($name) - Device: $keyValues->{Header_Device}";
  }

  InternalTimer( gettimeofday() + $hash->{INTERVAL}, "TA_CMI_JSON_GetStatus", $hash, 0 );

  return undef;
}

sub TA_CMI_JSON_extractDeviceName($) {
  my ($input) = @_;
  return $input;
}

sub TA_CMI_JSON_extractVersion($) {
  my ($input) = @_;
  return $input;
}

sub TA_CMI_JSON_extractReadings($$$) {
  my ( $hash, $keyValues, $id ) = @_;
  my $name = $hash->{NAME};

  my $readingNames = AttrVal($name, "readingNames$id", '');
  Log3 $name, 5, 'readingNames'.$id.": $readingNames";
  my @readingsArray = split(/ /, $readingNames); #1:T.Kollektor 5:T.Vorlauf

  for my $i (0 .. (@readingsArray-1)) {
    my ( $idx, $readingName ) = split(/\:/, $readingsArray[$i]);
    my $jsonKey = 'Data_'.$id.'_'.$idx.'_Value_Value';
    my $readingValue = $keyValues->{$jsonKey};
    Log3 $name, 5, "readingName: $readingName, key: $jsonKey, value: $readingValue";
    
    readingsBulkUpdateIfChanged($hash, $readingName, $readingValue);
  }

  return undef;
}

sub TA_CMI_JSON_Get ($@) {
  my ( $hash, $name, $opt, $args ) = @_;

  if ("update" eq $opt) {
    TA_CMI_JSON_PerformHttpRequest($hash);
    return undef;
  }

#  Log3 $name, 3, "ZoneMinder ($name) - Get done ...";
  return "Unknown argument $opt, choose one of update";

}

# Eval-Rückgabewert für erfolgreiches
# Laden des Moduls
1;


# Beginn der Commandref

=pod
=item [helper|device|command]
=item summary Kurzbeschreibung in Englisch was TA_COE_CMI steuert/unterstützt
=item summary_DE Kurzbeschreibung in Deutsch was TA_COE_CMI steuert/unterstützt

=begin html
 Englische Commandref in HTML
=end html

=begin html_DE
 Deustche Commandref in HTML
=end html

# Ende der Commandref
=cut
