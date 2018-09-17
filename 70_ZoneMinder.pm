package main;
use strict;
use warnings;
use HttpUtils;
use Crypt::MySQL qw(password41);
use DevIo;
use Digest::MD5 qw(md5 md5_hex md5_base64);

sub ZoneMinder_Initialize {
  my ($hash) = @_;

  $hash->{Clients} = "ZM_Monitor";

  $hash->{GetFn}     = "ZoneMinder_Get";
  $hash->{SetFn}     = "ZoneMinder_Set";
  $hash->{DefFn}     = "ZoneMinder_Define";
  $hash->{UndefFn}   = "ZoneMinder_Undef";
  $hash->{ReadFn}    = "ZoneMinder_Read";
  $hash->{ShutdownFn}= "ZoneMinder_Shutdown";
  $hash->{FW_detailFn} = "ZoneMinder_DetailFn";
  $hash->{WriteFn}   = "ZoneMinder_Write";
  $hash->{ReadyFn}   = "ZoneMinder_Ready";

  $hash->{AttrList} = "pubStreamUrl " . $readingFnAttributes;
  $hash->{MatchList} = { "1:ZM_Monitor" => "^.*" };

  Log3 '', 3, "ZoneMinder - Initialize done ...";
}

sub ZoneMinder_Define {
  my ( $hash, $def ) = @_;
  my @a = split( "[ \t][ \t]*", $def );

  my $name   = $a[0];
  $hash->{NAME} = $name;
 
  my $nrArgs = scalar @a;
  if ($nrArgs < 3) {
    my $msg = "ZoneMinder ($name) - Wrong syntax: define <name> ZoneMinder <ZM_URL>";
    Log3 $name, 2, $msg;
    return $msg;
  }

  my $module = $a[1];
  my $zmHost = $a[2];
  $hash->{helper}{ZM_HOST} = $zmHost;
  $zmHost .= ':6802' if (not $zmHost =~ m/:\d+$/);
  $hash->{DeviceName} = $zmHost;

  if ($nrArgs == 4 || $nrArgs > 6) {
    my $msg = "ZoneMinder ($name) - Wrong syntax: define <name> ZoneMinder <ZM_URL> [<ZM_USERNAME> <ZM_PASSWORD>] [<ZM_WEB_URL>]";
    Log3 $name, 2, $msg;
    return $msg;
  }
 
  if ($nrArgs == 5 || $nrArgs == 6) {
    $hash->{helper}{ZM_USERNAME} = $a[3];
    $hash->{helper}{ZM_PASSWORD} = $a[4];
    if ($a[5]) {
      $hash->{helper}{ZM_WEB_URL} = $a[5];
    } else {
      $hash->{helper}{ZM_WEB_URL} = "http://$a[2]/zm";
    }

    my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};
    my $zmUsername = ZoneMinder_urlencode($hash->{helper}{ZM_USERNAME});
    my $zmPassword = ZoneMinder_urlencode($hash->{helper}{ZM_PASSWORD});
    readingsSingleUpdate($hash, "ZMConsoleUrl", "$zmWebUrl/index.php?username=$zmUsername&password=$zmPassword&action=login&view=console", 0);
    ZoneMinder_API_Login($hash, 'old');
  }

#  Log3 $name, 3, "ZoneMinder ($name) - Define done ... module=$module, zmHost=$zmHost";

  DevIo_CloseDev($hash) if (DevIo_IsOpen($hash));
  DevIo_OpenDev($hash, 0, undef);

  return undef;
}

sub ZoneMinder_urlencode {
    my $s = shift;
    $s =~ s/ /+/g;
    $s =~ s/([^A-Za-z0-9\+-])/sprintf("%%%02X", ord($1))/seg;
    return $s;
}

sub ZoneMinder_API_Login {
  my ($hash, $loginMethod) = @_;
  my $name = $hash->{NAME};

  my $zmHost = $hash->{helper}{ZM_HOST};
  my $username = ZoneMinder_urlencode($hash->{helper}{ZM_USERNAME});
  my $password = ZoneMinder_urlencode($hash->{helper}{ZM_PASSWORD});

  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};
  my $loginUrl = '';
  if ($loginMethod eq 'new') {
    $loginUrl = "$zmWebUrl/api/login.json?user=$username&pass=$password";
  } else {
    $loginUrl = "$zmWebUrl/index.php?username=$username&password=$password&action=login&view=console";
  }
  $hash->{helper}{ZM_LOGIN_METHOD} = $loginMethod;

  Log3 $name, 0, "ZoneMinder ($name) - zmWebUrl: $zmWebUrl";
  my $apiParam = {
    url => $loginUrl,
    method => "POST",
    callback => \&ZoneMinder_API_Login_Callback,
    hash => $hash
  };
  HttpUtils_NonblockingGet($apiParam);
  
#  Log3 $name, 3, "ZoneMinder ($name) - ZoneMinder_API_Login err: $apiErr, data: $apiParam->{httpheader}";
  
  return undef;
}

sub ZoneMinder_API_Login_Callback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  $hash->{APILoginStatus} = $param->{code};

  if($err ne "") {
    Log3 $name, 0, "error while requesting ".$param->{url}." - $err";
    $hash->{APILoginError} = $err;
  } elsif($data ne "") {
    my $loginMethod = $hash->{helper}{ZM_LOGIN_METHOD};
    if ($data =~ m/Invalid username or password/) {
      $hash->{APILoginError} = "Invalid username or password.";
      ZoneMinder_API_Login( $hash, 'new' ) unless ($loginMethod eq 'new');
    } else {
      #Log3 $name, 5, "url ".$param->{url}." returned $param->{httpheader}";
      delete($defs{$name}{APILoginError});
      
      ZoneMinder_GetCookies($hash, $param->{httpheader});
      ZoneMinder_API_ReadHostInfo($hash);
      ZoneMinder_API_ReadConfig($hash);
      ZoneMinder_API_ReadMonitors($hash);

      InternalTimer(gettimeofday() + 3600, "ZoneMinder_API_Login", $hash, $loginMethod);
    }
  }
  
  return undef;
}

sub ZoneMinder_API_ReadHostInfo {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};

  my $apiParam = {
    url => "$zmWebUrl/api/host/getVersion.json",
    method => "GET",
    callback => \&ZoneMinder_API_ReadHostInfo_Callback,
    hash => $hash
  };

  if ($hash->{HTTPCookies}) {
    $apiParam->{header} .= "\r\n" if ($apiParam->{header});
    $apiParam->{header} .= "Cookie: " . $hash->{HTTPCookies};
  }

  HttpUtils_NonblockingGet($apiParam);  
}

sub ZoneMinder_API_ReadHostInfo_Callback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  if($err ne "") {
    Log3 $name, 0, "error while requesting ".$param->{url}." - $err";
    $hash->{ZM_VERSION} = 'error';
    $hash->{ZM_API_VERSION} = 'error';
  } elsif($data ne "") {
      
      my $zmVersion = ZoneMinder_GetConfigValueByKey($hash, $data, 'version');
      if (not $zmVersion) {
        $zmVersion = 'unknown';
      }
      $hash->{ZM_VERSION} = $zmVersion;

      my $zmApiVersion = ZoneMinder_GetConfigValueByKey($hash, $data, 'apiversion');
      if (not $zmApiVersion) {
        $zmApiVersion = 'unknown';
      }
      $hash->{ZM_API_VERSION} = $zmApiVersion;
  }

  return undef;
}

sub ZoneMinder_API_ReadConfig {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  #my $zmHost = $hash->{helper}{ZM_HOST};
  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};

  my $apiParam = {
    url => "$zmWebUrl/api/configs.json",
    method => "GET",
    callback => \&ZoneMinder_API_ReadConfig_Callback,
    hash => $hash
  };

  if ($hash->{HTTPCookies}) {
#    Log3 $name, 5, "$name.ZoneMinder_API_ReadConfig: Adding Cookies: " . $hash->{HTTPCookies};
    $apiParam->{header} .= "\r\n" if ($apiParam->{header});
    $apiParam->{header} .= "Cookie: " . $hash->{HTTPCookies};
  }

  HttpUtils_NonblockingGet($apiParam);
}

sub ZoneMinder_API_ReadConfig_Callback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  if($err ne "") {
    Log3 $name, 0, "error while requesting ".$param->{url}." - $err";
  } elsif($data ne "") {
      my $zmPathZms = ZoneMinder_GetConfigValueByName($hash, $data, 'ZM_PATH_ZMS');
      if ($zmPathZms) {
        $zmPathZms =~ s/\\//g;
        $hash->{helper}{ZM_PATH_ZMS} = $zmPathZms;
      }

      my $authHashSecret = ZoneMinder_GetConfigValueByName($hash, $data, 'ZM_AUTH_HASH_SECRET');
      if ($authHashSecret) {
        $hash->{helper}{ZM_AUTH_HASH_SECRET} = $authHashSecret;
        ZoneMinder_calcAuthHash($hash);
      }
  }

  return undef;
}

sub ZoneMinder_GetConfigValueByKey {
  my ($hash, $config, $key) = @_;
  my $searchString = '"'.$key.'":"';
  return ZoneMinder_GetFromJson($hash, $config, $searchString);
}

sub ZoneMinder_GetConfigValueByName {
  my ($hash, $config, $key) = @_;
  my $searchString = '"Name":"'.$key.'","Value":"';
  return ZoneMinder_GetFromJson($hash, $config, $searchString);
}

sub ZoneMinder_GetFromJson {
  my ($hash, $config, $searchString) = @_;
  my $name = $hash->{NAME};

  my $searchLength = length($searchString);
  my $startIdx = index($config, $searchString);
#  Log3 $name, 5, "$searchString found at $startIdx";
  $startIdx += $searchLength;
  my $endIdx = index($config, '"', $startIdx);
  my $frame = $endIdx - $startIdx;
  my $searchResult = substr $config, $startIdx, $frame;

#  Log3 $name, 5, "looking for $searchString - length: $searchLength. start: $startIdx. end: $endIdx. result: $searchResult";
  
  return $searchResult;
}

sub ZoneMinder_API_ReadMonitors {
  my ( $hash ) = @_;
  my $name = $hash->{NAME};

  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};

  my $apiParam = {
    url => "$zmWebUrl/api/monitors.json",
    method => "GET",
    callback => \&ZoneMinder_API_ReadMonitors_Callback,
    hash => $hash
  };

  if ($hash->{HTTPCookies}) {
#    Log3 $name, 5, "$name.ZoneMinder_API_ReadMonitors: Adding Cookies: " . $hash->{HTTPCookies};
    $apiParam->{header} .= "\r\n" if ($apiParam->{header});
    $apiParam->{header} .= "Cookie: " . $hash->{HTTPCookies};
  }

  return HttpUtils_NonblockingGet($apiParam);
}

sub ZoneMinder_API_ReadMonitors_Callback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $zmHost = $hash->{helper}{ZM_HOST};

  my @monitors = split(/\{"Monitor"\:\{/, $data);

  foreach my $monitorData (@monitors) {
    my $monitorId = ZoneMinder_GetConfigValueByKey($hash, $monitorData, 'Id');

    if ( $monitorId =~ /^[0-9]+$/ ) {
      my $monitorAddress = $name.'_'.$monitorId;
      my $newDevName = "ZM_Monitor_$monitorAddress";
      if(not defined($modules{ZM_Monitor}{defptr}{$monitorAddress})) {
        CommandDefine(undef, "$newDevName ZM_Monitor $monitorId");
        $attr{$newDevName}{room} = "ZM_Monitor";
      }
      ZoneMinder_UpdateMonitorAttributes($hash, $monitorData, $monitorAddress);
    }
  }

#  InternalTimer(gettimeofday() + 60, "ZoneMinder_API_ReadMonitors", $hash);

  return undef;  
}

sub ZoneMinder_UpdateMonitorAttributes {
  my ( $hash, $monitorData, $monitorId ) = @_;
  my $logDevHash = $modules{ZM_Monitor}{defptr}{$monitorId};
  if (not $logDevHash) {
    Log3 $hash, 3, "UpdateMonitorAttributes unable to find logical device with address $monitorId";
    return undef;
  }
  Log3 $hash, 5, "UpdateMonitorAttributes for address $monitorId";

  my $function = ZoneMinder_GetConfigValueByKey($hash, $monitorData, 'Function');
  my $enabled = ZoneMinder_GetConfigValueByKey($hash, $monitorData, 'Enabled');
  my $streamReplayBuffer = ZoneMinder_GetConfigValueByKey($hash, $monitorData, 'StreamReplayBuffer');
  
  readingsBeginUpdate($logDevHash);
  readingsBulkUpdateIfChanged($logDevHash, 'Function', $function);
  readingsBulkUpdateIfChanged($logDevHash, 'Enabled', $enabled);
  readingsBulkUpdateIfChanged($logDevHash, 'StreamReplayBuffer', $streamReplayBuffer);
  readingsEndUpdate($logDevHash, 1);
}

sub ZoneMinder_GetCookies {
    my ($hash, $header) = @_;
    my $name = $hash->{NAME};
    #Log3 $name, 5, "$name: looking for Cookies in $header";
    foreach my $cookie ($header =~ m/set-cookie: ?(.*)/gi) {
        #Log3 $name, 5, "$name: Set-Cookie: $cookie";
        $cookie =~ /([^,; ]+)=([^,; ]+)[;, ]*(.*)/;
        #Log3 $name, 4, "$name: Cookie: $1 Wert $2 Rest $3";
        $hash->{HTTPCookieHash}{$1}{Value} = $2;
        $hash->{HTTPCookieHash}{$1}{Options} = ($3 ? $3 : "");
    }
    $hash->{HTTPCookies} = join ("; ", map ($_ . "=".$hash->{HTTPCookieHash}{$_}{Value},
                                        sort keys %{$hash->{HTTPCookieHash}}));
}

sub ZoneMinder_Write {
  my ( $hash, $arguments) = @_;
  my $method = $arguments->{method};

  if ($method eq 'changeMonitorFunction') {

    my $zmMonitorId = $arguments->{zmMonitorId};
    my $zmFunction = $arguments->{zmFunction};
    Log3 $hash->{NAME}, 4, "method: $method, monitorId:$zmMonitorId, Function:$zmFunction";
    return ZoneMinder_API_ChangeMonitorState($hash, $zmMonitorId, $zmFunction, undef);

  } elsif ($method eq 'changeMonitorEnabled') {

    my $zmMonitorId = $arguments->{zmMonitorId};
    my $zmEnabled = $arguments->{zmEnabled};
    Log3 $hash->{NAME}, 4, "method: $method, monitorId:$zmMonitorId, Enabled:$zmEnabled";
    return ZoneMinder_API_ChangeMonitorState($hash, $zmMonitorId, undef, $zmEnabled);

  } elsif ($method eq 'changeMonitorAlarm') {

    my $zmMonitorId = $arguments->{zmMonitorId};
    my $zmAlarm = $arguments->{zmAlarm};
    Log3 $hash->{NAME}, 4, "method: $method, monitorId:$zmMonitorId, Alarm:$zmAlarm";
    return ZoneMinder_Trigger_ChangeAlarmState($hash, $zmMonitorId, $zmAlarm);

  }

  return undef;
}

sub ZoneMinder_API_ChangeMonitorState {
  my ( $hash, $zmMonitorId, $zmFunction, $zmEnabled ) = @_;
  my $name = $hash->{NAME};

  my $zmHost = $hash->{helper}{ZM_HOST};
  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};

  my $apiParam = {
    url => "$zmWebUrl/api/monitors/$zmMonitorId.json",
    method => "POST",
    callback => \&ZoneMinder_API_ChangeMonitorState_Callback,
    hash => $hash,
    zmMonitorId => $zmMonitorId,
    zmFunction => $zmFunction,
    zmEnabled => $zmEnabled
  };

  if ( $zmFunction ) {
    $apiParam->{data} = "Monitor[Function]=$zmFunction";
  } elsif ( $zmEnabled || $zmEnabled eq '0' ) {
    $apiParam->{data} = "Monitor[Enabled]=$zmEnabled";
  }
  #Log3 $name, 5, "ZoneMinder ($name) - url: ".$apiParam->{url}." data: ".$apiParam->{data};

  if ($hash->{HTTPCookies}) {
    $apiParam->{header} .= "\r\n" if ($apiParam->{header});
    $apiParam->{header} .= "Cookie: " . $hash->{HTTPCookies};
  }

  HttpUtils_NonblockingGet($apiParam);

#  Log3 $name, 3, "ZoneMinder ($name) - ZoneMinder_API_Login err: $apiErr, data: $apiParam";

  return undef;
}

sub ZoneMinder_API_ChangeMonitorState_Callback {
  my ($param, $err, $data) = @_;  
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  if ($data) {
    my $monitorId = $param->{zmMonitorId};
    my $logDevHash = $modules{ZM_Monitor}{defptr}{$name.'_'.$monitorId};
    my $function = $param->{zmFunction};
    my $enabled = $param->{zmEnabled};
    Log3 $name, 4, "ZM_Monitor ($name) - ChangeMonitorState callback data: $data, enabled: $enabled";

    if ($function) {
      readingsSingleUpdate($logDevHash, 'Function', $function, 1);
    } elsif ($enabled || $enabled eq '0') {
      readingsSingleUpdate($logDevHash, 'Enabled', $enabled, 1);
    }

  } else {
    Log3 $name, 2, "ZoneMinder ($name) - ChangeMonitorState callback err: $err";
  }
  
  return undef;
}

sub ZoneMinder_Trigger_ChangeAlarmState {
  my ( $hash, $zmMonitorId, $zmAlarm ) = @_;
  my $name = $hash->{NAME};

  my $msg = "$zmMonitorId|";
  if ( 'on' eq $zmAlarm ) {
    DevIo_SimpleWrite( $hash, $msg.'on|1|fhem', 2 );
  } elsif ( 'off' eq $zmAlarm ) {
    DevIo_SimpleWrite( $hash, $msg.'off|1|fhem', 2);
  } elsif ( $zmAlarm =~ /^on\-for\-timer/ ) {
    my $duration = $zmAlarm =~ s/on\-for\-timer\ /on\ /r;
    DevIo_SimpleWrite( $hash, $msg.$duration.'|1|fhem', 2);
  }

  return undef;
}

sub ZoneMinder_calcAuthHash {
  my ($hash) = @_;
  my ($sec,$min,$curHour,$dayOfMonth,$curMonth,$curYear,$wday,$yday,$isdst) = localtime();

  my $zmAuthHashSecret = $hash->{helper}{ZM_AUTH_HASH_SECRET};
  my $username = $hash->{helper}{ZM_USERNAME};
  my $password = $hash->{helper}{ZM_PASSWORD};
  my $hashedPassword = password41($password);

  my $authHash = $zmAuthHashSecret . $username . $hashedPassword . $curHour . $dayOfMonth . $curMonth . $curYear;
  my $authKey = md5_hex($authHash);
  $hash->{helper}{ZM_AUTH_KEY} = $authKey;

  InternalTimer(gettimeofday() + 3600, "ZoneMinder_calcAuthHash", $hash);

  return undef;
}



sub ZoneMinder_Shutdown {
  ZoneMinder_Undef(@_);
}  

sub ZoneMinder_Undef {
  my ($hash, $arg) = @_; 
  my $name = $hash->{NAME};

  DevIo_CloseDev($hash) if (DevIo_IsOpen($hash));
  RemoveInternalTimer($hash);

  return undef;
}

sub ZoneMinder_Read {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $data = DevIo_SimpleRead($hash);
  return if (!defined($data)); # connection lost

  my $buffer = $hash->{PARTIAL};
  $buffer .= $data;
  #as long as the buffer contains newlines
  while ($buffer =~ m/\n/) {
    my $msg;
    ($msg, $buffer) = split("\n", $buffer, 2);
    chomp $msg;
    $msg = "event:$msg";
#    Log3 $name, 3, "ZoneMinder ($name) incoming message $msg.";
    my $dispatchResult = Dispatch($hash, $msg, undef);
  }
  $hash->{PARTIAL} = $buffer;
}

sub ZoneMinder_DetailFn {
  my ( $FW_wname, $deviceName, $FW_room ) = @_;

  my $hash = $defs{$deviceName};
  my $zmConsoleUrl = ReadingsVal($deviceName, "ZMConsoleUrl", undef);
  if ($zmConsoleUrl) {
    return "<div><a href='$zmConsoleUrl' target='_blank'>Go to ZoneMinder console</a></div>";
  } else {
    return undef;
  }
}


sub ZoneMinder_Get {
  my ( $hash, $name, $opt, $args ) = @_;

  if ("updateMonitors" eq $opt) {
    ZoneMinder_API_ReadMonitors($hash);
    return undef;
  }

#  Log3 $name, 3, "ZoneMinder ($name) - Get done ...";
  return "Unknown argument $opt, choose one of updateMonitors";
}

sub ZoneMinder_Set {
  my ( $hash, $param ) = @_;

  my $name = $hash->{NAME};
#  Log3 $name, 3, "ZoneMinder ($name) - Set done ...";
  return undef;
}

sub ZoneMinder_Ready {
  my ( $hash ) = @_;

  return DevIo_OpenDev($hash, 1, undef ) if ( $hash->{STATE} eq "disconnected" );

  # This is relevant for Windows/USB only
  if(defined($hash->{USBDev})) {
    my $po = $hash->{USBDev};
    my ( $BlockingFlags, $InBytes, $OutBytes, $ErrorFlags ) = $po->status;
    return ( $InBytes > 0 );
  }
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
