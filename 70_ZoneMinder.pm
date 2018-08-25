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

  $hash->{AttrList} = "readingsConfig " . $readingFnAttributes;
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
    
    ZoneMinder_API_Login($hash);
  }

#  Log3 $name, 3, "ZoneMinder ($name) - Define done ... module=$module, zmHost=$zmHost";

  DevIo_CloseDev($hash) if (DevIo_IsOpen($hash));
  DevIo_OpenDev($hash, 0, undef);

  return undef;
}

sub ZoneMinder_API_Login {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $zmHost = $hash->{helper}{ZM_HOST};
  my $username = $hash->{helper}{ZM_USERNAME};
  my $password = $hash->{helper}{ZM_PASSWORD};

  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};
  Log3 $name, 0, "ZoneMinder ($name) - zmWebUrl: $zmWebUrl";
  my $apiParam = {
    url => "$zmWebUrl/index.php?username=$username&password=$password&action=login&view=console",
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
    if ($data =~ m/Invalid username or password/) {
      $hash->{APILoginError} = "Invalid username or password.";
    } else {
      Log3 $name, 5, "url ".$param->{url}." returned $param->{httpheader}";
      delete($defs{$name}{APILoginError});
      
      ZoneMinder_GetCookies($hash, $param->{httpheader});
      ZoneMinder_API_ReadConfig($hash);
    }
  }
  
  return undef;
}

sub ZoneMinder_API_ReadConfig {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $zmHost = $hash->{helper}{ZM_HOST};
  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};

  my $apiParam = {
    url => "$zmWebUrl/api/configs.json",
    method => "GET",
    callback => \&ZoneMinder_API_ReadConfig_Callback,
    hash => $hash
  };

  if ($hash->{HTTPCookies}) {
    Log3 $name, 5, "$name.ZoneMinder_API_ReadConfig: Adding Cookies: " . $hash->{HTTPCookies};
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
        $hash->{helper}{ZM_PATH_ZMS} = $zmPathZms;
      }

      my $authHashSecret = ZoneMinder_GetConfigValueByName($hash, $data, 'ZM_AUTH_HASH_SECRET');
      if ($authHashSecret) {
        $hash->{helper}{ZM_AUTH_HASH_SECRET} = $authHashSecret;
#        Log3 $name, 3, "url ".$param->{url}." returned $authHashSecret";
        ZoneMinder_calcAuthHash($hash);
      }
  }

  return undef;
}

sub ZoneMinder_GetConfigValueByKey {
  my ($hash, $config, $key) = @_;
  my $searchString = '"'.$key.'":';
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
  my $startIdx = index($config, $searchString) + $searchLength;
  my $endIdx = index($config, '"', $startIdx);
  my $frame = $endIdx - $startIdx;
  my $searchResult = substr $config, $startIdx, $frame;

  Log3 $name, 5, "looking for $searchString. length: $searchLength. start: $startIdx. end: $endIdx. result: $searchResult";
  
  return $searchResult;
}

sub ZoneMinder_API_ReadMonitorConfig {
  my ($hash, $zmMonitorId) = @_;
  my $name = $hash->{NAME};

  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};

  my $apiParam = {
    url => "$zmWebUrl/api/monitors/$zmMonitorId.json",
    method => "GET",
    callback => \&ZoneMinder_API_ReadMonitorConfig_Callback,
    hash => $hash
  };

  if ($hash->{HTTPCookies}) {
    Log3 $name, 5, "$name.ZoneMinder_API_ReadConfig: Adding Cookies: " . $hash->{HTTPCookies};
    $apiParam->{header} .= "\r\n" if ($apiParam->{header});
    $apiParam->{header} .= "Cookie: " . $hash->{HTTPCookies};
  }

  return HttpUtils_NonblockingGet($apiParam);
}

sub ZoneMinder_API_ReadMonitorConfig_Callback {
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  my $msg = "monitors:$data";

  my $dispatchResult = Dispatch($hash, $msg, undef);

  return undef;  
}

sub ZoneMinder_GetCookies {
    my ($hash, $header) = @_;
    my $name = $hash->{NAME};
    Log3 $name, 5, "$name: looking for Cookies in $header";
    foreach my $cookie ($header =~ m/set-cookie: ?(.*)/gi) {
        Log3 $name, 5, "$name: Set-Cookie: $cookie";
        $cookie =~ /([^,; ]+)=([^,; ]+)[;, ]*(.*)/;
        Log3 $name, 4, "$name: Cookie: $1 Wert $2 Rest $3";
        $hash->{HTTPCookieHash}{$1}{Value} = $2;
        $hash->{HTTPCookieHash}{$1}{Options} = ($3 ? $3 : "");
    }
    $hash->{HTTPCookies} = join ("; ", map ($_ . "=".$hash->{HTTPCookieHash}{$_}{Value},
                                        sort keys %{$hash->{HTTPCookieHash}}));
}

sub ZoneMinder_Write {
  my ( $hash, $arguments) = @_;
  my $method = $arguments->{method};
  my $parameter = $arguments->{parameter};
  Log3 $hash->{NAME}, 1, "method: $method, param:$parameter";
#  my $method = @arguments->{method};

  if ($method eq "GetConfigValueByKey") {
 #   my $parameter = $arguments->{parameter};
 #   my $data = $arguments->{data};
    my $data="";
    return ZoneMinder_GetConfigValueByKey($hash, $data, $parameter);
  } elsif ($method eq "monitors") {
    return ZoneMinder_API_ReadMonitorConfig($hash, $parameter);
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
  my $zmWebUrl = $hash->{helper}{ZM_WEB_URL};
  my $zmUsername = $hash->{helper}{ZM_USERNAME};
  my $zmPassword = $hash->{helper}{ZM_PASSWORD};

  return "<div><a href='$zmWebUrl?username=$zmUsername&password=$zmPassword&action=login&view=console' target='_blank'>Go to ZoneMinder console</a></div>";
}


sub ZoneMinder_Get {
  my ( $hash, $param ) = @_;

  my $name = $hash->{NAME};
#  Log3 $name, 3, "ZoneMinder ($name) - Get done ...";
  return undef;
}

sub ZoneMinder_Set {
  my ( $hash, $param ) = @_;

  my $name = $hash->{NAME};
#  Log3 $name, 3, "ZoneMinder ($name) - Set done ...";
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
