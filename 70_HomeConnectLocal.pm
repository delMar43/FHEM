# $Id$
package main;

use strict;
use warnings;
use JSON::PP;
use IO::Socket::INET;
use MIME::Base64;
use Digest::SHA qw(hmac_sha256);
use Crypt::Mode::CBC;


##############################################
# Initialize
##############################################

sub HomeConnectLocal_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}   = "HomeConnectLocal_Define";
    $hash->{UndefFn} = "HomeConnectLocal_Undefine";
    $hash->{SetFn}   = "HomeConnectLocal_Set";
    $hash->{GetFn}   = "HomeConnectLocal_Get";
    $hash->{AttrFn}  = "HomeConnectLocal_Attr";
    $hash->{ReadFn}  = "HomeConnectLocal_Read";

    no strict 'vars';

    $hash->{AttrList} =
          "disable:0,1 "
        . "encryptionKey "
        . "connectionType:TLS,AES "
        . "iv "
        . "deviceType:dishwasher,hob,washer,washerdryer "
        . "mappingDir "
        . "mappingPrefix "
        . $main::readingFnAttributes;

    use strict 'vars';
}


##############################################
# Define
##############################################

sub HomeConnectLocal_Define {
    my ($hash, $def) = @_;

    my @a = split("[ \t]+", $def);

    return "Usage: define <name> HomeConnectLocal <IP>"
        if @a < 3;

    my ($name, $type, $host) = @a;

    $hash->{NAME} = $name;
    $hash->{Host} = $host;

    $hash->{DeviceID} ||= sprintf(
        "%08x",
        int(rand(4294967296))
    );

    $hash->{STATE}   = "initialized";
    $hash->{PARTIAL} = "";

    Log3 $name, 3,
        "HomeConnectLocal ($name) - "
        . "Application DeviceID: $hash->{DeviceID}";

    Log3 $name, 3,
        "HomeConnectLocal ($name) - "
        . "Initialisiert für $host, "
        . "DeviceID=$hash->{DeviceID}";

    HomeConnectLocal_LoadMapping($hash);

    return undef;
}


##############################################
# Mapping Helpers
##############################################

sub HomeConnectLocal_NormalizeHex {
    my ($value) = @_;

    return ""
        if !defined $value;

    $value = "$value";

    $value =~ s/^\s+|\s+$//g;
    $value =~ s/^0x//i;

    return sprintf(
        "%04X",
        hex($value)
    ) if $value =~ /^[0-9A-Fa-f]+$/;

    return uc($value);
}


sub HomeConnectLocal_NormalizeProtocolUID {
    my ($value) = @_;

    return ""
        if !defined $value;

    $value = "$value";

    $value =~ s/^\s+|\s+$//g;

    return sprintf(
        "%04X",
        int($value)
    ) if $value =~ /^\d+$/;

    return sprintf(
        "%04X",
        hex($1)
    ) if $value =~ /^0x([0-9A-Fa-f]+)$/;

    return sprintf(
        "%04X",
        hex($value)
    ) if $value =~ /^[0-9A-Fa-f]{1,4}$/;

    return uc($value);
}


sub HomeConnectLocal_XmlDecode {
    my ($v) = @_;

    return ""
        if !defined $v;

    $v =~ s/&quot;/"/g;
    $v =~ s/&apos;/'/g;
    $v =~ s/&lt;/</g;
    $v =~ s/&gt;/>/g;
    $v =~ s/&amp;/&/g;
    $v =~ s/&#(\d+);/chr($1)/eg;
    $v =~ s/&#x([0-9A-Fa-f]+);/chr(hex($1))/eg;

    return $v;
}


sub HomeConnectLocal_ReadFile {
    my ($file) = @_;

    open(
        my $fh,
        "<",
        $file
    ) or return (
        undef,
        "Kann $file nicht öffnen: $!"
    );

    local $/;

    my $c = <$fh>;

    close($fh);

    return (
        $c,
        undef
    );
}


##############################################
# Mapping Files
##############################################

sub HomeConnectLocal_FindMappingPair {
    my ($hash) = @_;

    my $name = $hash->{NAME};

    my $dir = AttrVal(
        $name,
        "mappingDir",
        "/opt/fhem/FHEM/FHEM_HomeConnectLocal"
    );

    my $wanted = AttrVal(
        $name,
        "mappingPrefix",
        ""
    );

    opendir(
        my $dh,
        $dir
    ) or return (
        undef,
        undef,
        undef,
        "Mapping-Verzeichnis $dir kann nicht geöffnet werden: $!"
    );

    my @ff =
        sort
        grep {
            /_FeatureMapping\.xml$/i &&
            -f "$dir/$_"
        }
        readdir($dh);

    closedir($dh);

    if ($wanted ne "") {

        @ff = grep {
            /^\Q$wanted\E_FeatureMapping\.xml$/i
        } @ff;
    }

    return (
        undef,
        undef,
        undef,
        "Keine *_FeatureMapping.xml in $dir gefunden."
    ) if !@ff;

    my @pairs;

    for my $f (@ff) {

        (my $p = $f) =~
            s/_FeatureMapping\.xml$//i;

        my $d =
            $p . "_DeviceDescription.xml";

        if (-f "$dir/$d") {

            push @pairs, {
                prefix  => $p,
                feature => "$dir/$f",
                device  => "$dir/$d"
            };
        }
    }

    return (
        undef,
        undef,
        undef,
        "Keine zusammengehörigen Mapping-Dateien in $dir gefunden."
    ) if !@pairs;


    #
    # Bei mehreren Dateien anhand deviceType suchen.
    #
    if (
        @pairs > 1 &&
        $wanted eq ""
    ) {

        my $dt = lc(
            AttrVal(
                $name,
                "deviceType",
                ""
            )
        );

        if ($dt ne "") {

            my @m;

            for my $p (@pairs) {

                my ($x, $e) =
                    HomeConnectLocal_ReadFile(
                        $p->{device}
                    );

                next
                    if $e;

                if (
                    $x =~
                    m{
                        <description\b[^>]*>
                        .*?
                        <type>\s*([^<]+?)\s*</type>
                        .*?
                        </description>
                    }isx
                ) {

                    push @m, $p
                        if lc(
                            HomeConnectLocal_XmlDecode($1)
                        ) eq $dt;
                }
            }

            @pairs = @m
                if @m == 1;
        }
    }


    if (
        @pairs > 1 &&
        $wanted eq ""
    ) {

        return (
            undef,
            undef,
            undef,
            "Mehrere Mapping-Dateipaare gefunden: "
            . join(
                ", ",
                map {
                    $_->{prefix}
                } @pairs
            )
            . ". Bitte attr $name mappingPrefix <Prefix> setzen."
        );
    }


    return (
        $pairs[0]{prefix},
        $pairs[0]{device},
        $pairs[0]{feature},
        undef
    );
}


##############################################
# Load Mapping
##############################################

sub HomeConnectLocal_LoadMapping {
    my ($hash) = @_;

    my $name =
        $hash->{NAME};

    my (
        $prefix,
        $df,
        $ff,
        $err
    ) =
        HomeConnectLocal_FindMappingPair(
            $hash
        );

    if ($err) {

        Log3 $name, 2,
            "HomeConnectLocal ($name) - "
            . "XML Mapping: $err";

        $hash->{MappingLoaded} = 0;
        $hash->{MappingError}  = $err;

        readingsSingleUpdate(
            $hash,
            "mapping_state",
            "error",
            1
        );

        readingsSingleUpdate(
            $hash,
            "mapping_error",
            $err,
            1
        );

        return;
    }


    my ($dx, $de) =
        HomeConnectLocal_ReadFile(
            $df
        );

    my ($fx, $fe) =
        HomeConnectLocal_ReadFile(
            $ff
        );

    if (
        $de ||
        $fe
    ) {

        my $e =
            $de || $fe;

        Log3 $name, 1,
            "HomeConnectLocal ($name) - "
            . "XML Mapping: $e";

        $hash->{MappingLoaded} = 0;
        $hash->{MappingError}  = $e;
        delete $hash->{Mapping};

        readingsSingleUpdate(
            $hash,
            "mapping_state",
            "error",
            1
        );

        readingsSingleUpdate(
            $hash,
            "mapping_error",
            $e,
            1
        );

        return;
    }


    my (
        %fbu,
        %ubf,
        %ek,
        %ev,
        %etu,
        %meta,
        %ebe
    );


    #
    # Features
    #
    while (
        $fx =~
        m{
            <feature\b
            [^>]*
            \brefUID="([^"]+)"
            [^>]*>
            \s*([^<]+?)\s*
            </feature>
        }gisx
    ) {

        my $u =
            HomeConnectLocal_NormalizeHex(
                $1
            );

        my $f =
            HomeConnectLocal_XmlDecode(
                $2
            );

        $fbu{$u} = $f;
        $ubf{$f} = $u;
    }


    #
    # Errors
    #
    while (
        $fx =~
        m{
            <error\b
            [^>]*
            \brefEID="([^"]+)"
            [^>]*>
            \s*([^<]+?)\s*
            </error>
        }gisx
    ) {

        $ebe{
            HomeConnectLocal_NormalizeHex(
                $1
            )
        } =
            HomeConnectLocal_XmlDecode(
                $2
            );
    }


    #
    # Enums
    #
    while (
        $fx =~
        m{
            <enumDescription\b([^>]*)>
            (.*?)
            </enumDescription>
        }gisx
    ) {

        my ($a, $b) =
            ($1, $2);

        my ($en) =
            $a =~
            /\brefENID="([^"]+)"/i;

        my ($key) =
            $a =~
            /\benumKey="([^"]+)"/i;

        next
            if !defined($en) ||
               !defined($key);

        $en =
            HomeConnectLocal_NormalizeHex(
                $en
            );

        $ek{$en} =
            HomeConnectLocal_XmlDecode(
                $key
            );

        while (
            $b =~
            m{
                <enumMember\b
                [^>]*
                \brefValue="([^"]+)"
                [^>]*>
                \s*([^<]*?)\s*
                </enumMember>
            }gisx
        ) {

            $ev{$en}{
                HomeConnectLocal_XmlDecode(
                    $1
                )
            } =
                HomeConnectLocal_XmlDecode(
                    $2
                );
        }
    }


    #
    # DeviceDescription-Metadaten je UID
    #
    # Die Attribute werden generisch aus status/setting/event/option
    # sowie activeProgram/selectedProgram gelesen. Dadurch koennen
    # spaetere Auswertungen (Enums, Zonen, initValue, min/max, stepSize
    # usw.) aus den XML-Dateien abgeleitet werden, ohne Geraetetabellen
    # im Perl-Modul zu pflegen.
    #
    while (
        $dx =~
        m{
            <(status|setting|event|option|activeProgram|selectedProgram)\b
            ([^>]*)
            >
        }gisx
    ) {

        my ($kind, $a) = ($1, $2);

        my ($u) =
            $a =~ /\buid="([^"]+)"/i;

        next if !defined($u);

        my $nu =
            HomeConnectLocal_NormalizeHex($u);

        $meta{$nu}{kind} = $kind;

        while (
            $a =~ /\b([A-Za-z][A-Za-z0-9_]*)="([^"]*)"/g
        ) {
            my ($k, $v) = ($1, HomeConnectLocal_XmlDecode($2));
            $meta{$nu}{$k} = $v;
        }

        if (defined($meta{$nu}{enumerationType})) {
            $etu{$nu} =
                HomeConnectLocal_NormalizeHex(
                    $meta{$nu}{enumerationType}
                );
        }
    }


    #
    # Device Info
    #
    my %di;

    if (
        $dx =~
        m{
            <description\b[^>]*>
            (.*?)
            </description>
        }isx
    ) {

        my $d =
            $1;

        for my $f (
            qw(
                type
                brand
                model
                version
                revision
            )
        ) {

            if (
                $d =~
                m{
                    <$f>
                    \s*([^<]*?)\s*
                    </$f>
                }isx
            ) {

                $di{$f} =
                    HomeConnectLocal_XmlDecode(
                        $1
                    );
            }
        }
    }


    $hash->{Mapping} = {
        FeatureByUID  => \%fbu,
        UIDByFeature  => \%ubf,
        EnumKeyByENID => \%ek,
        EnumValues    => \%ev,
        EnumTypeByUID => \%etu,
        MetaByUID     => \%meta,
        ErrorByEID    => \%ebe,
        DeviceInfo    => \%di
    };


    $hash->{MappingPrefix} =
        $prefix;

    $hash->{MappingDeviceFile} =
        $df;

    $hash->{MappingFeatureFile} =
        $ff;

    $hash->{MappingLoaded} =
        1;

    delete
        $hash->{MappingError};


    if (
        exists
        $hash->{READINGS}{mapping_error}
    ) {

        readingsDelete(
            $hash,
            "mapping_error"
        );
    }


    Log3 $name, 3,
        "HomeConnectLocal ($name) - "
        . "XML Mapping geladen: "
        . "Prefix=$prefix, "
        . "Features="
        . scalar(keys %fbu)
        . ", Enums="
        . scalar(keys %ek)
        . ", Enum-UIDs="
        . scalar(keys %etu);


    readingsBeginUpdate(
        $hash
    );

    readingsBulkUpdate(
        $hash,
        "mapping_state",
        "loaded"
    );

    readingsBulkUpdate(
        $hash,
        "mapping_prefix",
        $prefix
    );

    readingsBulkUpdate(
        $hash,
        "mapping_features",
        scalar(keys %fbu)
    );

    readingsBulkUpdate(
        $hash,
        "mapping_enums",
        scalar(keys %ek)
    );


    for my $f (
        qw(
            type
            brand
            model
            version
            revision
        )
    ) {

        readingsBulkUpdate(
            $hash,
            "mapping_$f",
            $di{$f}
        ) if exists
            $di{$f};
    }


    readingsEndUpdate(
        $hash,
        1
    );

    return 1;
}


##############################################
# Mapping
##############################################

sub HomeConnectLocal_GetMappedFeature {
    my ($hash, $uid) = @_;

    return undef
        if !defined($uid) ||
           !$hash->{MappingLoaded};

    return
        $hash->{Mapping}{FeatureByUID}{
            HomeConnectLocal_NormalizeProtocolUID(
                $uid
            )
        };
}


sub HomeConnectLocal_GetZoneReadingName {
    my ($hash, $feature) = @_;

    return undef
        if !defined($feature) ||
           !$hash->{MappingLoaded};

    # Nur Features der Form ...Zone.<id>.<property>.
    return undef
        if $feature !~ /^(.*\.Zone\.)(\d+)\.([^.]+)$/;

    my ($prefix, $zone_id, $property) =
        ($1, $2, $3);

    # Die ZoneSelector-UID derselben Zone direkt aus dem
    # FeatureMapping bestimmen. Keine feste Zonentabelle.
    my $selector_feature =
        $prefix . $zone_id . ".ZoneSelector";

    my $selector_uid =
        $hash->{Mapping}{UIDByFeature}{$selector_feature};

    return undef
        if !defined($selector_uid);

    my $meta =
        $hash->{Mapping}{MetaByUID}{$selector_uid};

    return undef
        if ref($meta) ne 'HASH';

    my $selector_value =
        $meta->{initValue};

    # Falls kein initValue vorhanden ist, ist bei den Home-Connect-
    # Zonen die numerische ID selbst der Selector-Wert. Das ist keine
    # Zonentabelle, sondern nur der aus dem Featurepfad gelesene Wert.
    $selector_value = $zone_id
        if !defined($selector_value) ||
           $selector_value eq '';

    my $enum_type =
        $hash->{Mapping}{EnumTypeByUID}{$selector_uid};

    return undef
        if !defined($enum_type);

    my $zone_name =
        $hash->{Mapping}{EnumValues}{$enum_type}{$selector_value};

    return undef
        if !defined($zone_name) ||
           $zone_name eq '';

    my $reading =
        $zone_name . "_" . $property;

    $reading =~ s/[^A-Za-z0-9_.-]/_/g;

    return $reading;
}


sub HomeConnectLocal_GetShortReadingName {
    my ($hash, $feature, $uid) = @_;

    return undef
        if !defined($feature) ||
           $feature eq '';

    # Zonenname vollstaendig aus DeviceDescription + FeatureMapping
    # ableiten, z.B. Zone.100.PowerLevel -> FrontLeft_PowerLevel.
    my $zone_reading =
        HomeConnectLocal_GetZoneReadingName(
            $hash,
            $feature
        );

    return $zone_reading
        if defined($zone_reading) &&
           $zone_reading ne '';

    my @p = split(/\./, $feature);
    return undef if !@p;

    my $r = $p[-1];

    # Wenn eine Zone zwar erkannt, aber in der XML nicht aufgeloest
    # werden konnte, bleibt der bisherige eindeutige Fallback erhalten.
    if (
        @p >= 3 &&
        $p[-3] eq 'Zone' &&
        $p[-2] =~ /^\d+$/
    ) {
        $r = 'Zone_' . $p[-2] . '_' . $p[-1];
    }

    $r =~ s/[^A-Za-z0-9_.-]/_/g;

    return $r;
}


sub HomeConnectLocal_MapProgramValue {
    my ($hash, $value) = @_;

    return $value
        if !defined($value) ||
           ref($value);

    # 0 bedeutet bei den Program-Referenzen "kein Programm" und soll
    # nicht gegen eine Feature-UID aufgeloest werden.
    return $value
        if $value !~ /^\d+$/ ||
           $value == 0;

    my $pu =
        HomeConnectLocal_NormalizeProtocolUID($value);

    my $pf =
        $hash->{Mapping}{FeatureByUID}{$pu};

    return $value
        if !defined($pf);

    Log3 $hash->{NAME}, 5,
        "HomeConnectLocal ($hash->{NAME}) - "
        . "PROGRAM MAP: $value -> $pu -> $pf";

    return $1
        if $pf =~ /\.Program\.(.+)$/;

    return $pf;
}


sub HomeConnectLocal_MapValue {
    my ($hash, $uid, $value) = @_;

    return $value
        if !defined($value);

    return encode_json($value)
        if ref($value);

    return $value
        if !$hash->{MappingLoaded};

    my $nu =
        HomeConnectLocal_NormalizeProtocolUID($uid);

    my $feature =
        $hash->{Mapping}{FeatureByUID}{$nu};

    # ActiveProgram / SelectedProgram nicht anhand fester UIDs erkennen,
    # sondern anhand des Feature-Namens aus der FeatureMapping.xml.
    # Das funktioniert damit auch fuer zonale Programme.
    if (
        defined($feature) &&
        $feature =~ /\.(?:ActiveProgram|SelectedProgram)$/
    ) {
        return HomeConnectLocal_MapProgramValue(
            $hash,
            $value
        );
    }

    my $et =
        $hash->{Mapping}{EnumTypeByUID}{$nu};

    if (
        defined($et) &&
        exists($hash->{Mapping}{EnumValues}{$et}{$value})
    ) {
        my $mapped =
            $hash->{Mapping}{EnumValues}{$et}{$value};

        # Die Art des Enums kommt aus der FeatureMapping.xml.
        # Fuer *.EnumType.PowerLevel sind die dort hinterlegten
        # numerischen Bezeichnungen 10,15,...90 die Anzeige fuer
        # 1.0,1.5,...9.0. Sonderwerte wie Off/KeepWarm/Boost bleiben Text.
        my $enum_key =
            $hash->{Mapping}{EnumKeyByENID}{$et};

        if (
            defined($enum_key) &&
            $enum_key =~ /\.EnumType\.PowerLevel$/ &&
            defined($mapped) &&
            $mapped =~ /^\d+$/ &&
            $mapped >= 10 &&
            $mapped <= 90
        ) {
            return sprintf('%.1f', $mapped / 10);
        }

        return $mapped;
    }

    return $value;
}


sub HomeConnectLocal_UpdateMappedValue {
    my ($hash, $uid, $value) = @_;

    return
        if !defined($uid) ||
           !$hash->{MappingLoaded};

    my $f =
        HomeConnectLocal_GetMappedFeature(
            $hash,
            $uid
        );

    return
        if !defined($f);

    my $r =
        HomeConnectLocal_GetShortReadingName(
            $hash,
            $f,
            $uid
        );

    return
        if !defined($r) ||
           $r eq "";

    my $mv =
        HomeConnectLocal_MapValue(
            $hash,
            $uid,
            $value
        );

    readingsSingleUpdate(
        $hash,
        $r,
        $mv,
        1
    );

    Log3 $hash->{NAME}, 5,
        "HomeConnectLocal ($hash->{NAME}) - "
        . "MAP $uid -> $f -> $r = $mv";
}


##############################################
# Random / Base64
##############################################

sub HomeConnectLocal_RandomBytes {
    my ($length) = @_;

    my $data = '';

    if (
        open(
            my $fh,
            '<',
            '/dev/urandom'
        )
    ) {

        binmode($fh);

        my $r =
            read(
                $fh,
                $data,
                $length
            );

        close($fh);

        return $data
            if defined($r) &&
               $r == $length;
    }


    $data .=
        chr(
            int(rand(256))
        )
        for 1 .. $length;

    return $data;
}


sub HomeConnectLocal_Base64UrlDecode {
    my ($v) = @_;

    return undef
        if !defined($v);

    $v =~
        s/^\s+|\s+$//g;

    $v =~
        tr/-_/+\//;

    $v .= '='
        while length($v) % 4;

    return
        decode_base64(
            $v
        );
}


##############################################
# AES
#
# Bleibt im Modul, wird für unseren aktuellen
# TLS-Test aber nicht verändert.
##############################################

sub HomeConnectLocal_AESInit {
    my ($hash, $psk, $iv) = @_;

    my $n = $hash->{NAME};

    if (!defined($psk) || length($psk) != 32) {
        Log3 $n, 1,
            "HomeConnectLocal ($n) - AES: PSK muss exakt 32 Byte lang sein.";
        return;
    }

    if (!defined($iv) || length($iv) != 16) {
        Log3 $n, 1,
            "HomeConnectLocal ($n) - AES: IV muss exakt 16 Byte lang sein.";
        return;
    }

    #
    # hcpy:
    #
    # enckey = HMAC-SHA256(psk, "ENC")
    # mackey = HMAC-SHA256(psk, "MAC")
    #
    $hash->{AES_ENC_KEY} =
        hmac_sha256(
            "ENC",
            $psk
        );

    $hash->{AES_MAC_KEY} =
        hmac_sha256(
            "MAC",
            $psk
        );

    #
    # Der originale IV bleibt unverändert.
    #
    # Er wird für die HMAC-Berechnung bei JEDER
    # Nachricht verwendet.
    #
    $hash->{AES_IV} = $iv;

    #
    # CBC-Zustand.
    #
    # hcpy verwendet zwei getrennte, stateful
    # AES-CBC-Instanzen.
    #
    # Wir bilden das in Perl durch getrennte
    # aktuelle IVs nach.
    #
    $hash->{AES_TX_IV} = $iv;
    $hash->{AES_RX_IV} = $iv;

    #
    # hcpy:
    #
    # last_rx_hmac = bytes(16)
    # last_tx_hmac = bytes(16)
    #
    $hash->{AES_LAST_TX_HMAC} =
        "\x00" x 16;

    $hash->{AES_LAST_RX_HMAC} =
        "\x00" x 16;

    #
    # Zähler nur zur Diagnose.
    #
    $hash->{AES_TX_COUNT} = 0;
    $hash->{AES_RX_COUNT} = 0;

    Log3 $n, 3,
        "HomeConnectLocal ($n) - "
        . "AES Verschlüsselung initialisiert "
        . "PSK=32 Byte IV=16 Byte.";

    return 1;
}


sub HomeConnectLocal_AESMac {
    my ($hash, $direction, $last_hmac, $enc) = @_;

    #
    # Exakt entsprechend hcpy:
    #
    # hmac_msg =
    #     original_iv
    #     + direction
    #     + previous_hmac
    #     + encrypted_message
    #
    my $msg =
          $hash->{AES_IV}
        . $direction
        . $last_hmac
        . $enc;

    return substr(
        hmac_sha256(
            $msg,
            $hash->{AES_MAC_KEY}
        ),
        0,
        16
    );
}


sub HomeConnectLocal_AESEncrypt {
    my ($hash, $clear) = @_;

    my $n = $hash->{NAME};

    #
    # hcpy arbeitet mit UTF-8 Bytes.
    #
    # encode_json liefert für unsere bisherigen
    # Protokollnachrichten bereits einen Byte-String.
    #

    my $clear_len =
        length($clear);

    #
    # Exakt das Home-Connect-Padding aus hcpy.
    #
    my $pad_len =
        16 - ($clear_len % 16);

    #
    # Ein einzelnes Padding-Byte reicht nicht,
    # weil mindestens:
    #
    # 00 + padLength
    #
    # benötigt wird.
    #
    if ($pad_len == 1) {
        $pad_len += 16;
    }

    my $padding =
          "\x00"
        . HomeConnectLocal_RandomBytes(
            $pad_len - 2
        )
        . chr($pad_len);

    my $plain =
        $clear . $padding;

    #
    # Das muss block-aligned sein.
    #
    if (length($plain) % 16 != 0) {

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES TX Paddingfehler: "
            . "plainLen="
            . length($plain);

        return undef;
    }

    my $current_iv =
        $hash->{AES_TX_IV};

    #
    # WICHTIG:
    #
    # Crypt::Mode::CBC bekommt bereits gepaddete
    # Daten und darf deshalb kein zusätzliches
    # Padding hinzufügen.
    #
    my $cbc =
        Crypt::Mode::CBC->new(
            'AES',
            0
        );

    my $enc =
        $cbc->encrypt(
            $plain,
            $hash->{AES_ENC_KEY},
            $current_iv
        );

    if (!defined($enc)) {

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES TX Verschlüsselung fehlgeschlagen.";

        return undef;
    }

    #
    # Bei CBC wird für die nächste Nachricht
    # der letzte Ciphertext-Block zum IV.
    #
    my $next_iv =
        substr(
            $enc,
            -16
        );

    #
    # hcpy:
    #
    # last_tx_hmac =
    #   HMAC(
    #       originalIV
    #       + 0x45
    #       + previousTXHMAC
    #       + ciphertext
    #   )[0:16]
    #
    my $mac =
        HomeConnectLocal_AESMac(
            $hash,
            "\x45",
            $hash->{AES_LAST_TX_HMAC},
            $enc
        );
   
    #
    # Erst nach erfolgreicher Berechnung
    # Zustand fortschreiben.
    #
    $hash->{AES_TX_IV} =
        $next_iv;

    $hash->{AES_LAST_TX_HMAC} =
        $mac;

    $hash->{AES_TX_COUNT}++;

    Log3 $n, 4,
        "HomeConnectLocal ($n) - "
        . "AES TX #"
        . $hash->{AES_TX_COUNT}
        . " clear="
        . $clear_len
        . " padded="
        . length($plain)
        . " encrypted="
        . length($enc)
        . " framePayload="
        . (length($enc) + 16);

    return
        $enc . $mac;
}


sub HomeConnectLocal_AESDecrypt {
    my ($hash, $buf) = @_;

    my $n = $hash->{NAME};

    #
    # Mindestens:
    #
    # 16 Byte Ciphertext
    # 16 Byte HMAC
    #
    if (!defined($buf) || length($buf) < 32) {

        Log3 $n, 2,
            "HomeConnectLocal ($n) - "
            . "AES RX Nachricht zu kurz.";

        return undef;
    }

    if (length($buf) % 16 != 0) {

        Log3 $n, 2,
            "HomeConnectLocal ($n) - "
            . "AES RX Nachricht nicht "
            . "16-Byte-ausgerichtet: "
            . length($buf);

        return undef;
    }


    my $enc =
        substr(
            $buf,
            0,
            -16
        );

    my $their_hmac =
        substr(
            $buf,
            -16
        );


    #
    # ---------------------------------------------------------
    # Aktuellen RX-State sichern.
    #
    # WICHTIG:
    # Hier wird noch NICHTS verändert.
    # ---------------------------------------------------------
    #
    my $previous_hmac =
        $hash->{AES_LAST_RX_HMAC};

    my $current_iv =
        $hash->{AES_RX_IV};


    #
    # Erwarteten HMAC berechnen.
    #
    # Referenz:
    #
    # original IV
    # + 0x43
    # + previous RX HMAC
    # + ciphertext
    #
    my $our_hmac =
        HomeConnectLocal_AESMac(
            $hash,
            "\x43",
            $previous_hmac,
            $enc
        );


    #
    # ---------------------------------------------------------
    # HMAC FEHLER
    #
    # Jetzt alle relevanten Werte ausgeben.
    # ---------------------------------------------------------
    #
    if ($their_hmac ne $our_hmac) {

        my $next_rx =
            ($hash->{AES_RX_COUNT} // 0) + 1;

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX #$next_rx HMAC FEHLER";

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX framePayload="
            . length($buf)
            . " encrypted="
            . length($enc);

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX receivedHMAC="
            . unpack("H*", $their_hmac);

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX calculatedHMAC="
            . unpack("H*", $our_hmac);

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX previousHMAC="
            . unpack("H*", $previous_hmac);

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX currentCBCIV="
            . unpack("H*", $current_iv);

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX originalIV="
            . unpack("H*", $hash->{AES_IV});

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX ciphertextFirst16="
            . unpack(
                "H*",
                substr($enc, 0, 16)
            );

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX ciphertextLast16="
            . unpack(
                "H*",
                substr($enc, -16)
            );

        #
        # Ganz wichtig:
        #
        # Bei HMAC-Fehler KEINEN State verändern.
        #
        return undef;
    }


    #
    # Erst nach erfolgreicher HMAC-Prüfung
    # RX-HMAC übernehmen.
    #
    $hash->{AES_LAST_RX_HMAC} =
        $their_hmac;


    #
    # CBC entschlüsseln.
    #
    my $cbc =
        Crypt::Mode::CBC->new(
            'AES',
            0
        );

    my $clear =
        $cbc->decrypt(
            $enc,
            $hash->{AES_ENC_KEY},
            $current_iv
        );


    if (!defined($clear) || !length($clear)) {

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX Entschlüsselung fehlgeschlagen.";

        return undef;
    }


    #
    # CBC-State für nächste Nachricht.
    #
    $hash->{AES_RX_IV} =
        substr(
            $enc,
            -16
        );


    #
    # Padding entfernen.
    #
    my $pad_len =
        ord(
            substr(
                $clear,
                -1,
                1
            )
        );


    if (
        $pad_len <= 0 ||
        $pad_len > length($clear)
    ) {

        Log3 $n, 1,
            "HomeConnectLocal ($n) - "
            . "AES RX Padding ungültig: "
            . "$pad_len";

        return undef;
    }


    my $result =
        substr(
            $clear,
            0,
            length($clear) - $pad_len
        );


    $hash->{AES_RX_COUNT}++;


    Log3 $n, 4,
        "HomeConnectLocal ($n) - "
        . "AES RX #"
        . $hash->{AES_RX_COUNT}
        . " encrypted="
        . length($enc)
        . " clear="
        . length($result);


    return $result;
}

##############################################
# WebSocket Upgrade
##############################################

sub HomeConnectLocal_OpenWebSocket {
    my (
        $hash,
        $socket,
        $host_header
    ) = @_;

    my $name =
        $hash->{NAME};


    my $key =
        encode_base64(
            HomeConnectLocal_RandomBytes(
                16
            ),
            ""
        );

    $key =~
        s/\s//g;


    my $crlf =
        "\r\n";


    my $req =
          "GET /homeconnect HTTP/1.1"
        . $crlf
        . "Host: "
        . $host_header
        . $crlf
        . "Upgrade: websocket"
        . $crlf
        . "Connection: Upgrade"
        . $crlf
        . "Sec-WebSocket-Key: "
        . $key
        . $crlf
        . "Sec-WebSocket-Version: 13"
        . $crlf
        . $crlf;


    my $len =
        length($req);

    my $offset =
        0;


    while ($offset < $len) {

        my $written =
            syswrite(
                $socket,
                $req,
                $len - $offset,
                $offset
            );


        if (!defined($written)) {

            Log3 $name, 1,
                "HomeConnectLocal ($name) - "
                . "WebSocket Handshake konnte "
                . "nicht gesendet werden: $!";

            return 0;
        }


        if ($written == 0) {

            Log3 $name, 1,
                "HomeConnectLocal ($name) - "
                . "WebSocket Handshake: "
                . "Socket beim Schreiben geschlossen.";

            return 0;
        }


        $offset +=
            $written;
    }


    Log3 $name, 4,
        "HomeConnectLocal ($name) - "
        . "WebSocket Handshake: "
        . "$offset/$len Bytes gesendet.";


    $hash->{WSHandshake} =
        1;


    readingsSingleUpdate(
        $hash,
        "state",
        "handshake_sent",
        1
    );


    return 1;
}


##############################################
# Connect
##############################################

sub HomeConnectLocal_Connect {
    my ($hash) = @_;

    return
        if !$hash;

    my $name =
        $hash->{NAME};

    return
        if !$name;

    return
        if AttrVal(
            $name,
            "disable",
            0
        );

    my $host =
        $hash->{Host};

    my $ct =
        uc(
            AttrVal(
                $name,
                "connectionType",
                "TLS"
            )
        );

    $hash->{ConnectionType} =
        $ct;

    my $psk =
        HomeConnectLocal_Base64UrlDecode(
            AttrVal(
                $name,
                "encryptionKey",
                ""
            )
        );

    if (
        !defined($psk) ||
        length($psk) != 32
    ) {

        Log3 $name, 1,
            "HomeConnectLocal ($name) - "
            . "encryptionKey ungültig!";

        return;
    }

    HomeConnectLocal_Undefine(
        $hash
    );

    $hash->{PARTIAL} =
        "";

    delete
        $hash->{WSHandshake};


    #
    # ==========================================
    # AES
    # ==========================================
    #
    if ($ct eq "AES") {

        my $iv =
            HomeConnectLocal_Base64UrlDecode(
                AttrVal(
                    $name,
                    "iv",
                    ""
                )
            );

        if (
            !defined($iv) ||
            length($iv) != 16
        ) {

            Log3 $name, 1,
                "HomeConnectLocal ($name) - "
                . "AES IV ungültig "
                . "(16 Byte erwartet).";

            return;
        }

        return
            if !HomeConnectLocal_AESInit(
                $hash,
                $psk,
                $iv
            );

        my $s =
            IO::Socket::INET->new(
                PeerAddr => $host,
                PeerPort => 80,
                Proto    => 'tcp',
                Timeout  => 5
            );

        if (!$s) {

            Log3 $name, 2,
                "HomeConnectLocal ($name) - "
                . "AES Verbindung zu "
                . "$host:80 fehlgeschlagen: $!";

            InternalTimer(
                time() + 10,
                "HomeConnectLocal_Connect",
                $hash,
                0
            );

            return;
        }

        Log3 $name, 3,
            "HomeConnectLocal ($name) - "
            . "TCP/AES Kanal zu "
            . "$host:80 verbunden.";

        my $ok =
            HomeConnectLocal_OpenWebSocket(
                $hash,
                $s,
                "$host:80"
            );

        if (!$ok) {

            close($s);

            delete
                $hash->{WSHandshake};

            readingsSingleUpdate(
                $hash,
                "state",
                "closed",
                1
            );

            InternalTimer(
                time() + 10,
                "HomeConnectLocal_Connect",
                $hash,
                0
            );

            return;
        }

        $s->blocking(0);

        $hash->{FD} =
            fileno($s);

        $hash->{CD} =
            $s;

        $main::selectlist{$name} =
            $hash;

        Log3 $name, 3,
            "HomeConnectLocal ($name) - "
            . "AES WebSocket Handshake gesendet.";

        return;
    }


    #
    # ==========================================
    # TLS / PSK
    # ==========================================
    #
    # FUNKTIONIERENDEN TLS-PFAD NICHT VERÄNDERN.
    #

    my $hex =
        unpack(
            "H*",
            $psk
        );

    my @ip =
        split(
            /\./,
            $host
        );

    my $lp =
        10000 +
        $ip[-1];

    $hash->{LocalPort} =
        $lp;

    Log3 $name, 3,
        "HomeConnectLocal ($name) - "
        . "Starte TLS-PSK Proxy "
        . "auf Port $lp";

    system(
        "pkill -f 'socat.*LISTEN:$lp'"
    );

    my $cmd =
          "socat "
        . "TCP-LISTEN:$lp,reuseaddr,fork "
        . "EXEC:'openssl s_client "
        . "-connect $host\\:443 "
        . "-tls1_2 "
        . "-psk $hex "
        . "-noservername "
        . "-cipher ECDHE-PSK-CHACHA20-POLY1305 "
        . "-quiet "
        . "-ign_eof',nofork &";

    system($cmd);

    InternalTimer(
        time() + 0.5,
        sub {

            my $s =
                IO::Socket::INET->new(
                    PeerAddr => '127.0.0.1',
                    PeerPort => $lp,
                    Proto    => 'tcp',
                    Blocking => 0
                );

            if (!$s) {

                Log3 $name, 2,
                    "HomeConnectLocal ($name) - "
                    . "Verbindung zum TLS-Proxy "
                    . "auf Port $lp fehlgeschlagen.";

                InternalTimer(
                    time() + 10,
                    "HomeConnectLocal_Connect",
                    $hash,
                    0
                );

                return;
            }

            $hash->{FD} =
                fileno($s);

            $hash->{CD} =
                $s;

            $main::selectlist{$name} =
                $hash;

            Log3 $name, 3,
                "HomeConnectLocal ($name) - "
                . "TCP/TLS Kanal aktiv.";

            my $ok =
                HomeConnectLocal_OpenWebSocket(
                    $hash,
                    $s,
                    $host
                );

            if ($ok) {

                Log3 $name, 3,
                    "HomeConnectLocal ($name) - "
                    . "WebSocket Handshake gesendet.";
            }

        },
        $hash
    );

    return;
}
##############################################
# WebSocket Frame
##############################################

sub HomeConnectLocal_WSFrame {
    my (
        $payload,
        $opcode
    ) = @_;

    $opcode = 0x1
        if !defined($opcode);


    my $len =
        length($payload);


    my $frame =
        pack(
            "C",
            0x80 |
            ($opcode & 0x0f)
        );


    my $mask =
        HomeConnectLocal_RandomBytes(
            4
        );


    if ($len < 126) {

        $frame .=
            pack(
                "C",
                0x80 | $len
            );

    }
    elsif ($len <= 65535) {

        $frame .=
              pack(
                  "C",
                  0x80 | 126
              )
            . pack(
                  "n",
                  $len
              );

    }
    else {

        my $hi =
            int(
                $len /
                4294967296
            );

        my $lo =
            $len %
            4294967296;


        $frame .=
              pack(
                  "C",
                  0x80 | 127
              )
            . pack(
                  "N2",
                  $hi,
                  $lo
              );
    }


    my $m =
        '';


    for (
        my $i = 0;
        $i < $len;
        $i++
    ) {

        $m .= chr(
            ord(
                substr(
                    $payload,
                    $i,
                    1
                )
            )
            ^
            ord(
                substr(
                    $mask,
                    $i % 4,
                    1
                )
            )
        );
    }


    return
          $frame
        . $mask
        . $m;
}


sub HomeConnectLocal_WSFrame_Control {
    my ($op, $p) = @_;

    $p = ''
        if !defined($p);

    return undef
        if length($p) > 125;

    return
        HomeConnectLocal_WSFrame(
            $p,
            $op
        );
}


##############################################
# Send
##############################################

sub HomeConnectLocal_SendRaw {
    my ($hash, $json) = @_;

    my $n =
        $hash->{NAME};

    my $s =
        $hash->{CD};

    return
        if !$s;


    Log3 $n, 3,
        "HomeConnectLocal ($n) - "
        . "SEND RAW: $json";


    my (
        $payload,
        $op
    ) =
        (
            $json,
            0x1
        );


    if (
        ($hash->{ConnectionType} // "TLS")
        eq "AES"
    ) {

        $payload =
            HomeConnectLocal_AESEncrypt(
                $hash,
                $json
            );

        return undef
            if !defined($payload);

        $op =
            0x2;
    }


    my $frame =
        HomeConnectLocal_WSFrame(
            $payload,
            $op
        );


    my $len =
        length($frame);

    my $off =
        0;


    my $was_blocking =
        $s->blocking();


    $s->blocking(1);


    while ($off < $len) {

        my $written =
            syswrite(
                $s,
                $frame,
                $len - $off,
                $off
            );


        if (!defined($written)) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "SEND fehlgeschlagen "
                . "bei $off/$len Bytes: $!";

            $s->blocking(
                $was_blocking
            );

            return undef;
        }


        if ($written == 0) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "SEND Socket geschlossen "
                . "bei $off/$len Bytes.";

            $s->blocking(
                $was_blocking
            );

            return undef;
        }


        $off +=
            $written;
    }


    $s->blocking(
        $was_blocking
    );


    Log3 $n, 4,
        "HomeConnectLocal ($n) - "
        . "SEND vollständig: "
        . "$off/$len Bytes";


    return 1;
}


sub HomeConnectLocal_SendJSON {
    my ($hash, $data) = @_;

    return
        HomeConnectLocal_SendRaw(
            $hash,
            encode_json(
                $data
            )
        );
}


sub HomeConnectLocal_SendProtocol {
    my (
        $hash,
        $res,
        $ver,
        $act,
        $data
    ) = @_;


    return
        if !defined(
            $hash->{SessionID}
        ) ||
           !defined(
            $hash->{TxMsgID}
        );


    my $m = {
        sID      => 0 + $hash->{SessionID},
        msgID    => 0 + $hash->{TxMsgID},
        resource => $res,
        version  => 0 + $ver,
        action   => $act
    };


    $m->{data} =
        [$data]
        if defined($data);


    my $r =
        HomeConnectLocal_SendRaw(
            $hash,
            encode_json($m)
        );


    #
    # Nur bei erfolgreichem Versand hochzählen.
    #
    $hash->{TxMsgID}++
        if $r;


    return $r;
}


##############################################
# Protocol / Initial Handshake
##############################################

sub HomeConnectLocal_InitialHandshake {
    my ($hash, $d) = @_;

    return
        if !$d ||
           ref($d) ne 'HASH' ||
           !$d->{resource};

    my $n =
        $hash->{NAME};

    my $r =
        $d->{resource};

    my $a =
        $d->{action} // "";

    my $ct =
        $hash->{ConnectionType}
        // uc(
            AttrVal(
                $n,
                "connectionType",
                "TLS"
            )
        );


    #
    # =========================================================
    # /ei/initialValues
    # =========================================================
    #
    if (
        $r eq "/ei/initialValues" &&
        $a eq "POST"
    ) {

        my $sid =
            $d->{sID};

        my $mid =
            $d->{msgID};

        my $ed =
            (
                ref($d->{data}) eq 'ARRAY' &&
                @{$d->{data}} &&
                ref($d->{data}[0]) eq 'HASH'
            )
            ? $d->{data}[0]{edMsgID}
            : undef;

        if (
            !defined($sid) ||
            !defined($mid) ||
            !defined($ed)
        ) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "/ei/initialValues unvollständig.";

            return;
        }

        $hash->{SessionID} =
            $sid;

        $hash->{TxMsgID} =
            $ed;

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "/ei/initialValues empfangen: "
            . "sID=$sid "
            . "msgID=$mid "
            . "edMsgID=$ed "
            . "connectionType=$ct";


        #
        # =====================================================
        # initialValues RESPONSE
        # =====================================================
        #

        my $ok;

        if ($ct eq "AES") {

            #
            # Exakte JSON-Feldreihenfolge für AES.
            #
            my $json =
                  '{"sID":'
                . (0 + $sid)
                . ',"msgID":'
                . (0 + $mid)
                . ',"resource":"/ei/initialValues"'
                . ',"version":2'
                . ',"action":"RESPONSE"'
                . ',"data":[{'
                . '"deviceType":"Application",'
                . '"deviceName":"Homeassistant",'
                . '"deviceID":'
                . encode_json(
                    $hash->{DeviceID}
                )
                . '}]}';

            $ok =
                HomeConnectLocal_SendRaw(
                    $hash,
                    $json
                );
        }
        else {

            #
            # TLS unverändert über JSON::PP.
            #
            my $response = {
                sID      => 0 + $sid,
                msgID    => 0 + $mid,
                resource => "/ei/initialValues",
                version  => 2,
                action   => "RESPONSE",
                data     => [
                    {
                        deviceType => "Application",
                        deviceName => "Homeassistant",
                        deviceID   => $hash->{DeviceID}
                    }
                ]
            };

            $ok =
                HomeConnectLocal_SendJSON(
                    $hash,
                    $response
                );
        }

        if (!$ok) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "initialValues RESPONSE "
                . "konnte nicht gesendet werden.";

            return;
        }

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "initialValues RESPONSE gesendet.";


        #
        # =====================================================
        # AES
        # =====================================================
        #
        if ($ct eq "AES") {

            Log3 $n, 3,
                "HomeConnectLocal ($n) - "
                . "AES Handshake: sende /ci/services "
                . "in Referenz-JSON-Reihenfolge";

            my $json =
                  '{"sID":'
                . (0 + $sid)
                . ',"msgID":'
                . (0 + $ed)
                . ',"resource":"/ci/services"'
                . ',"version":1'
                . ',"action":"GET"}';

            my $services_ok =
                HomeConnectLocal_SendRaw(
                    $hash,
                    $json
                );

            if (!$services_ok) {

                Log3 $n, 1,
                    "HomeConnectLocal ($n) - "
                    . "AES /ci/services konnte "
                    . "nicht gesendet werden.";

                return;
            }

            $hash->{TxMsgID} =
                $ed + 1;

            readingsSingleUpdate(
                $hash,
                "state",
                "aes_wait_services",
                1
            );

            return;
        }


        #
        # =====================================================
        # TLS
        # =====================================================
        #
        # FUNKTIONIERENDEN TLS-PFAD NICHT VERÄNDERN.
        #

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Sende /ci/services";

        HomeConnectLocal_SendProtocol(
            $hash,
            "/ci/services",
            1,
            "GET"
        );


        my $nonce =
            encode_base64(
                HomeConnectLocal_RandomBytes(
                    32
                ),
                ""
            );

        $nonce =~
            tr!+/!-_!;

        $nonce =~
            s/=+$//;


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Sende /ci/authentication";

        HomeConnectLocal_SendProtocol(
            $hash,
            "/ci/authentication",
            2,
            "GET",
            {
                nonce => $nonce
            }
        );


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Sende /ci/info";

        HomeConnectLocal_SendProtocol(
            $hash,
            "/ci/info",
            2,
            "GET"
        );


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Sende /iz/info";

        HomeConnectLocal_SendProtocol(
            $hash,
            "/iz/info",
            1,
            "GET"
        );


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Sende /ni/info";

        HomeConnectLocal_SendProtocol(
            $hash,
            "/ni/info",
            1,
            "GET"
        );


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Sende /ei/deviceReady";

        HomeConnectLocal_SendProtocol(
            $hash,
            "/ei/deviceReady",
            2,
            "NOTIFY"
        );


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Sende /ro/allDescriptionChanges";

        HomeConnectLocal_SendProtocol(
            $hash,
            "/ro/allDescriptionChanges",
            1,
            "GET"
        );


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Sende /ro/allMandatoryValues";

        HomeConnectLocal_SendProtocol(
            $hash,
            "/ro/allMandatoryValues",
            1,
            "GET"
        );


        readingsSingleUpdate(
            $hash,
            "state",
            "initializing",
            1
        );

        return;
    }


    #
    # =========================================================
    # AES /ci/registeredDevices
    # =========================================================
    #
    if (
        $ct eq "AES" &&
        $r eq "/ci/registeredDevices" &&
        $a eq "NOTIFY"
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES /ci/registeredDevices empfangen.";

        readingsSingleUpdate(
            $hash,
            "registeredDevices",
            encode_json($d),
            1
        );

        if (
            ref($d->{data}) eq 'ARRAY'
        ) {

            for my $dev (
                @{$d->{data}}
            ) {

                next
                    if ref($dev) ne 'HASH';

                next
                    if !defined(
                        $dev->{deviceID}
                    );

                if (
                    $dev->{deviceID} eq
                    $hash->{DeviceID}
                ) {

                    Log3 $n, 3,
                        "HomeConnectLocal ($n) - "
                        . "AES eigene Application gefunden: "
                        . "deviceID=$dev->{deviceID}, "
                        . "connected="
                        . (
                            $dev->{connected}
                            ? 1
                            : 0
                        );

                    last;
                }
            }
        }

        return;
    }


    #
    # =========================================================
    # /ci/services RESPONSE
    # =========================================================
    #
    if (
        $r eq "/ci/services" &&
        $a eq "RESPONSE"
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "/ci/services empfangen.";

        readingsSingleUpdate(
            $hash,
            "services",
            encode_json($d),
            1
        );


        #
        # TLS:
        # Die weiteren Requests wurden im funktionierenden
        # TLS-Pfad bereits nach initialValues versendet.
        #
        if ($ct ne "AES") {
            return;
        }


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES /ci/services RESPONSE erfolgreich.";


        my $sid =
            $hash->{SessionID};

        my $mid =
            $hash->{TxMsgID};


        if (
            !defined($sid) ||
            !defined($mid)
        ) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "AES /ci/authentication nicht möglich: "
                . "SessionID oder TxMsgID fehlt.";

            readingsSingleUpdate(
                $hash,
                "state",
                "aes_authentication_error",
                1
            );

            return;
        }


        my $nonce =
            encode_base64(
                HomeConnectLocal_RandomBytes(
                    32
                ),
                ""
            );

        $nonce =~
            tr!+/!-_!;

        $nonce =~
            s/=+$//;

        $hash->{AES_AUTH_NONCE} =
            $nonce;


        my $json =
              '{"sID":'
            . (0 + $sid)
            . ',"msgID":'
            . (0 + $mid)
            . ',"resource":"/ci/authentication"'
            . ',"version":2'
            . ',"action":"GET"'
            . ',"data":[{"nonce":'
            . encode_json(
                $nonce
            )
            . '}]}';


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES Handshake: sende /ci/authentication "
            . "msgID=$mid";


        my $auth_ok =
            HomeConnectLocal_SendRaw(
                $hash,
                $json
            );


        if (!$auth_ok) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "AES /ci/authentication konnte "
                . "nicht gesendet werden.";

            readingsSingleUpdate(
                $hash,
                "state",
                "aes_authentication_error",
                1
            );

            return;
        }


        $hash->{TxMsgID} =
            $mid + 1;


        readingsSingleUpdate(
            $hash,
            "state",
            "aes_wait_authentication",
            1
        );


        return;
    }


    #
    # =========================================================
    # AES /ci/authentication RESPONSE
    # =========================================================
    #
    if (
        $ct eq "AES" &&
        $r eq "/ci/authentication" &&
        $a eq "RESPONSE"
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES /ci/authentication RESPONSE erfolgreich.";

        readingsSingleUpdate(
            $hash,
            "authentication",
            encode_json($d),
            1
        );


        my $sid =
            $hash->{SessionID};

        my $mid =
            $hash->{TxMsgID};


        my $json =
              '{"sID":'
            . (0 + $sid)
            . ',"msgID":'
            . (0 + $mid)
            . ',"resource":"/ci/info"'
            . ',"version":2'
            . ',"action":"GET"}';


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES Handshake: sende /ci/info "
            . "msgID=$mid";


        my $ok =
            HomeConnectLocal_SendRaw(
                $hash,
                $json
            );


        if (!$ok) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "AES /ci/info konnte nicht gesendet werden.";

            return;
        }


        $hash->{TxMsgID} =
            $mid + 1;


        readingsSingleUpdate(
            $hash,
            "state",
            "aes_wait_ci_info",
            1
        );


        return;
    }


    #
    # =========================================================
    # AES /ci/info RESPONSE
    # =========================================================
    #
    if (
        $ct eq "AES" &&
        $r eq "/ci/info" &&
        $a eq "RESPONSE"
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES /ci/info RESPONSE erfolgreich.";

        readingsSingleUpdate(
            $hash,
            "ci_info",
            encode_json($d),
            1
        );


        my $sid =
            $hash->{SessionID};

        my $mid =
            $hash->{TxMsgID};


        my $json =
              '{"sID":'
            . (0 + $sid)
            . ',"msgID":'
            . (0 + $mid)
            . ',"resource":"/iz/info"'
            . ',"version":1'
            . ',"action":"GET"}';


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES Handshake: sende /iz/info "
            . "msgID=$mid";


        my $ok =
            HomeConnectLocal_SendRaw(
                $hash,
                $json
            );


        if (!$ok) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "AES /iz/info konnte nicht gesendet werden.";

            return;
        }


        $hash->{TxMsgID} =
            $mid + 1;


        readingsSingleUpdate(
            $hash,
            "state",
            "aes_wait_iz_info",
            1
        );


        return;
    }


     #
    # =========================================================
    # AES /iz/info RESPONSE
    #
    # Referenz:
    # Nach /iz/info kommt zuerst /ei/deviceReady.
    # Erst DANACH wird /ni/info abgefragt.
    # =========================================================
    #
    if (
        $ct eq "AES" &&
        $r eq "/iz/info" &&
        $a eq "RESPONSE"
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES /iz/info RESPONSE erfolgreich.";

        readingsSingleUpdate(
            $hash,
            "iz_info",
            encode_json($d),
            1
        );


        my $sid =
            $hash->{SessionID};

        my $mid =
            $hash->{TxMsgID};


        #
        # =====================================================
        # /ei/deviceReady
        #
        # Aktuelle homeconnect_websocket Referenz:
        #
        # /iz/info
        #     ↓
        # /ei/deviceReady NOTIFY
        #     ↓
        # /ni/info
        # =====================================================
        #

        my $json =
              '{"sID":'
            . (0 + $sid)
            . ',"msgID":'
            . (0 + $mid)
            . ',"resource":"/ei/deviceReady"'
            . ',"version":2'
            . ',"action":"NOTIFY"}';


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES Handshake: sende /ei/deviceReady "
            . "VOR /ni/info "
            . "msgID=$mid";


        my $ok =
            HomeConnectLocal_SendRaw(
                $hash,
                $json
            );


        if (!$ok) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "AES /ei/deviceReady konnte "
                . "nicht gesendet werden.";

            return;
        }


        $hash->{TxMsgID} =
            $mid + 1;


        #
        # deviceReady ist NOTIFY.
        #
        # Darauf wird KEINE RESPONSE erwartet.
        #
        # Direkt danach folgt laut Referenz /ni/info.
        #

        $mid =
            $hash->{TxMsgID};


        $json =
              '{"sID":'
            . (0 + $sid)
            . ',"msgID":'
            . (0 + $mid)
            . ',"resource":"/ni/info"'
            . ',"version":1'
            . ',"action":"GET"}';


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES Handshake: sende /ni/info "
            . "NACH deviceReady "
            . "msgID=$mid";


        $ok =
            HomeConnectLocal_SendRaw(
                $hash,
                $json
            );


        if (!$ok) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "AES /ni/info konnte "
                . "nicht gesendet werden.";

            return;
        }


        $hash->{TxMsgID} =
            $mid + 1;


        readingsSingleUpdate(
            $hash,
            "state",
            "aes_wait_ni_info",
            1
        );


        return;
    }

    #
    # =========================================================
    # AES /ni/info RESPONSE
    #
    # Der eigentliche AES-Handshake ist jetzt abgeschlossen.
    #
    # Reihenfolge:
    #
    # /iz/info RESPONSE
    #      ↓
    # /ei/deviceReady NOTIFY
    #      ↓
    # /ni/info GET
    #      ↓
    # /ni/info RESPONSE
    #      ↓
    # /ro/allDescriptionChanges GET
    # =========================================================
    #
    if (
        $ct eq "AES" &&
        $r eq "/ni/info" &&
        $a eq "RESPONSE"
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES /ni/info RESPONSE erfolgreich.";

        readingsSingleUpdate(
            $hash,
            "ni_info",
            encode_json($d),
            1
        );


        #
        # Falls /ni/info selbst einen Fehlercode enthält,
        # hier zunächst sauber protokollieren.
        #
        if (
            exists($d->{code}) &&
            defined($d->{code}) &&
            $d->{code} != 0
        ) {

            Log3 $n, 2,
                "HomeConnectLocal ($n) - "
                . "AES /ni/info Fehler: "
                . "code=$d->{code}";

            readingsSingleUpdate(
                $hash,
                "last_error",
                encode_json($d),
                1
            );

            readingsSingleUpdate(
                $hash,
                "state",
                "aes_ni_info_error_" . $d->{code},
                1
            );

            return;
        }


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES Handshake erfolgreich abgeschlossen.";


        #
        # =====================================================
        # Jetzt Remote-Object-Beschreibung abfragen.
        #
        # WICHTIG:
        # deviceReady wird hier NICHT erneut gesendet.
        # =====================================================
        #

        my $sid =
            $hash->{SessionID};

        my $mid =
            $hash->{TxMsgID};


        if (
            !defined($sid) ||
            !defined($mid)
        ) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "/ro/allDescriptionChanges nicht möglich: "
                . "SessionID oder TxMsgID fehlt.";

            return;
        }


        my $json =
              '{"sID":'
            . (0 + $sid)
            . ',"msgID":'
            . (0 + $mid)
            . ',"resource":"/ro/allDescriptionChanges"'
            . ',"version":1'
            . ',"action":"GET"}';


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES: sende /ro/allDescriptionChanges "
            . "msgID=$mid";


        my $ok =
            HomeConnectLocal_SendRaw(
                $hash,
                $json
            );


        if (!$ok) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "AES /ro/allDescriptionChanges konnte "
                . "nicht gesendet werden.";

            readingsSingleUpdate(
                $hash,
                "state",
                "aes_description_changes_error",
                1
            );

            return;
        }


        $hash->{TxMsgID} =
            $mid + 1;


        readingsSingleUpdate(
            $hash,
            "state",
            "aes_wait_description_changes",
            1
        );


        return;
    }

    #
    # =========================================================
    # AES /ro/allDescriptionChanges RESPONSE
    #
    # Bleibt für spätere Tests erhalten.
    # Im aktuellen AES-Test wird dieser Block nicht erreicht.
    # =========================================================
    #
    if (
        $ct eq "AES" &&
        $r eq "/ro/allDescriptionChanges" &&
        $a eq "RESPONSE"
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES /ro/allDescriptionChanges "
            . "RESPONSE erfolgreich.";

        readingsSingleUpdate(
            $hash,
            "descriptionChanges",
            encode_json($d),
            1
        );


        my $sid =
            $hash->{SessionID};

        my $mid =
            $hash->{TxMsgID};


        my $json =
              '{"sID":'
            . (0 + $sid)
            . ',"msgID":'
            . (0 + $mid)
            . ',"resource":"/ro/allMandatoryValues"'
            . ',"version":1'
            . ',"action":"GET"}';


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "AES Handshake: sende /ro/allMandatoryValues "
            . "msgID=$mid";


        my $ok =
            HomeConnectLocal_SendRaw(
                $hash,
                $json
            );


        if (!$ok) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "AES /ro/allMandatoryValues konnte "
                . "nicht gesendet werden.";

            return;
        }


        $hash->{TxMsgID} =
            $mid + 1;


        readingsSingleUpdate(
            $hash,
            "state",
            "aes_wait_mandatory_values",
            1
        );


        return;
    }


    #
    # =========================================================
    # registeredDevices allgemein / TLS
    # =========================================================
    #
    if (
        $r eq "/ci/registeredDevices" &&
        (
            $a eq "RESPONSE" ||
            $a eq "NOTIFY"
        )
    ) {

        readingsSingleUpdate(
            $hash,
            "registeredDevices",
            encode_json($d),
            1
        );

        return;
    }


    #
    # =========================================================
    # Weitere Antworten
    # =========================================================
    #
    my %rr = (
        "/ci/authentication"        => "authentication",
        "/ci/info"                  => "ci_info",
        "/iz/info"                  => "iz_info",
        "/ni/info"                  => "ni_info",
        "/ei/deviceReady"           => "deviceReady",
        "/ro/allDescriptionChanges" => "descriptionChanges"
    );

    if (
        exists($rr{$r}) &&
        (
            $a eq "RESPONSE" ||
            $a eq "NOTIFY"
        )
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Antwort empfangen: "
            . "resource=$r "
            . "action=$a";

        readingsSingleUpdate(
            $hash,
            $rr{$r},
            encode_json($d),
            1
        );

        return;
    }


    #
    # =========================================================
    # Values
    # =========================================================
    #
    if (
        (
            $r eq "/ro/allMandatoryValues" ||
            $r eq "/ro/values"
        )
        &&
        (
            $a eq "RESPONSE" ||
            $a eq "NOTIFY"
        )
    ) {

        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "Werte empfangen: "
            . "resource=$r "
            . "action=$a";


        #
        # Komplette Antwort für Debugging anzeigen
        #
        Log3 $n, 4,
            "HomeConnectLocal ($n) - "
            . "VALUES RAW: "
            . encode_json($d);


        #
        # =====================================================
        # Protokollfehler innerhalb einer RESPONSE erkennen
        #
        # Beispiel vom Kochfeld:
        #
        # {
        #   "action":"RESPONSE",
        #   "resource":"/ro/allMandatoryValues",
        #   "code":403
        # }
        #
        # Das darf NICHT als erfolgreiche Initialisierung
        # behandelt werden.
        # =====================================================
        #
        if (
            exists($d->{code}) &&
            defined($d->{code}) &&
            $d->{code} != 0
        ) {

            Log3 $n, 2,
                "HomeConnectLocal ($n) - "
                . "Request $r abgelehnt: "
                . "code=$d->{code}";


            readingsSingleUpdate(
                $hash,
                "last_error",
                encode_json($d),
                1
            );


            readingsSingleUpdate(
                $hash,
                "state",
                "protocol_error_" . $d->{code},
                1
            );


            return;
        }


        #
        # =====================================================
        # Erfolgreiche Values-Antwort speichern
        # =====================================================
        #
        readingsSingleUpdate(
            $hash,
            $r eq "/ro/allMandatoryValues"
                ? "mandatoryValues"
                : "values",
            encode_json($d),
            1
        );


        #
        # UID/Value-Mapping erfolgt zentral in
        # HomeConnectLocal_ProcessPayload().
        # Dadurch wird jedes Reading nur einmal aktualisiert.


        #
        # =====================================================
        # Erst eine ERFOLGREICHE allMandatoryValues RESPONSE
        # setzt das Gerät auf connected.
        # =====================================================
        #
        if (
            $r eq "/ro/allMandatoryValues"
        ) {

            readingsSingleUpdate(
                $hash,
                "state",
                "connected",
                1
            );


            Log3 $n, 3,
                "HomeConnectLocal ($n) - "
                . "Initialisierung abgeschlossen.";
        }


        return;
    }


    #
    # =========================================================
    # Protocol Error
    # =========================================================
    #
    if (
        exists(
            $d->{code}
        )
    ) {

        Log3 $n, 2,
            "HomeConnectLocal ($n) - "
            . "Protokollfehler: "
            . encode_json($d);

        readingsSingleUpdate(
            $hash,
            "last_error",
            encode_json($d),
            1
        );

        return;
    }


    Log3 $n, 4,
        "HomeConnectLocal ($n) - "
        . "Unbehandelte Nachricht: "
        . encode_json($d);

    return;
}
##############################################
# Process JSON Payload
##############################################

sub HomeConnectLocal_ProcessPayload {
    my ($hash, $payload) = @_;

    my $n =
        $hash->{NAME};

    my $d;


    eval {
        $d =
            decode_json(
                $payload
            );
    };


    if ($@) {

        Log3 $n, 2,
            "HomeConnectLocal ($n) - "
            . "JSON Decode Fehler: $@";

        Log3 $n, 4,
            "HomeConnectLocal ($n) - "
            . "Payload: $payload";

        return;
    }


    return
        if ref($d) ne 'HASH';


    Log3 $n, 4,
        "HomeConnectLocal ($n) - "
        . "RX resource="
        . ($d->{resource} // "-")
        . " action="
        . ($d->{action} // "-")
        . " msgID="
        . (
            defined(
                $d->{msgID}
            )
            ? $d->{msgID}
            : "-"
        );


    if (
        exists(
            $d->{resource}
        )
    ) {

        readingsSingleUpdate(
            $hash,
            "last_resource",
            $d->{resource},
            1
        );
    }


    if (
        exists(
            $d->{action}
        )
    ) {

        readingsSingleUpdate(
            $hash,
            "last_action",
            $d->{action},
            1
        );
    }


    #
    # Mapping
    #
    if (
        ref($d->{data}) eq 'ARRAY'
    ) {

        for my $i (
            @{$d->{data}}
        ) {

            next
                if ref($i) ne 'HASH';


            if (
                exists(
                    $i->{uid}
                ) &&
                exists(
                    $i->{value}
                )
            ) {

                HomeConnectLocal_UpdateMappedValue(
                    $hash,
                    $i->{uid},
                    $i->{value}
                );
            }
        }
    }


    #
    # Protokoll
    #
    HomeConnectLocal_InitialHandshake(
        $hash,
        $d
    );


    return;
}


##############################################
# Read
##############################################

sub HomeConnectLocal_Read {
    my ($hash) = @_;

    my $n =
        $hash->{NAME};

    my $s =
        $hash->{CD};

    return
        if !$s;


    my $buf =
        '';


    my $rd =
        sysread(
            $s,
            $buf,
            65536
        );


    if (!defined($rd)) {

        return
            if $!{EAGAIN} ||
               $!{EWOULDBLOCK};


        Log3 $n, 2,
            "HomeConnectLocal ($n) - "
            . "Socket Lesefehler: $!";


        HomeConnectLocal_Close(
            $hash
        );

        return;
    }


    if ($rd == 0) {

        Log3 $n, 2,
            "HomeConnectLocal ($n) - "
            . "Socket geschlossen.";


        HomeConnectLocal_Close(
            $hash
        );

        return;
    }


    $hash->{PARTIAL} .=
        $buf;


    #
    # ==========================================
    # HTTP -> WebSocket
    # ==========================================
    #
    if (
        $hash->{WSHandshake}
    ) {

        my $e =
            index(
                $hash->{PARTIAL},
                "\r\n\r\n"
            );


        return
            if $e < 0;


        my $h =
            substr(
                $hash->{PARTIAL},
                0,
                $e + 4
            );


        substr(
            $hash->{PARTIAL},
            0,
            $e + 4
        ) = "";


        if (
            $h !~
            m/^HTTP\/1\.[01]\s+101\b/im
        ) {

            Log3 $n, 1,
                "HomeConnectLocal ($n) - "
                . "WebSocket Handshake "
                . "fehlgeschlagen: $h";


            HomeConnectLocal_Close(
                $hash
            );

            return;
        }


        $hash->{WSHandshake} =
            0;


        #
        # Fragment-State zurücksetzen.
        #
        delete $hash->{WS_FRAGMENT_DATA};
        delete $hash->{WS_FRAGMENT_OPCODE};


        readingsSingleUpdate(
            $hash,
            "state",
            "websocket_connected",
            1
        );


        Log3 $n, 3,
            "HomeConnectLocal ($n) - "
            . "WebSocket Verbindung "
            . "erfolgreich geöffnet.";
    }


    #
    # ==========================================
    # WebSocket Frames
    # ==========================================
    #
    while (
        length(
            $hash->{PARTIAL}
        ) >= 2
    ) {

        my $b1 =
            ord(
                substr(
                    $hash->{PARTIAL},
                    0,
                    1
                )
            );


        my $b2 =
            ord(
                substr(
                    $hash->{PARTIAL},
                    1,
                    1
                )
            );


        #
        # FIN-Bit
        #
        my $fin =
            ($b1 & 0x80)
            ? 1
            : 0;


        #
        # Opcode
        #
        my $op =
            $b1 & 0x0f;


        my $masked =
            $b2 & 0x80;


        my $pl =
            $b2 & 0x7f;


        my $pos =
            2;


        #
        # Extended Payload Length 16 Bit
        #
        if ($pl == 126) {

            last
                if length(
                    $hash->{PARTIAL}
                ) < $pos + 2;


            $pl =
                unpack(
                    "n",
                    substr(
                        $hash->{PARTIAL},
                        $pos,
                        2
                    )
                );


            $pos +=
                2;

        }

        #
        # Extended Payload Length 64 Bit
        #
        elsif ($pl == 127) {

            last
                if length(
                    $hash->{PARTIAL}
                ) < $pos + 8;


            my (
                $hi,
                $lo
            ) =
                unpack(
                    "N2",
                    substr(
                        $hash->{PARTIAL},
                        $pos,
                        8
                    )
                );


            $pl =
                $hi * 4294967296
                + $lo;


            $pos +=
                8;
        }


        #
        # Mask
        #
        my $mask =
            '';


        if ($masked) {

            last
                if length(
                    $hash->{PARTIAL}
                ) < $pos + 4;


            $mask =
                substr(
                    $hash->{PARTIAL},
                    $pos,
                    4
                );


            $pos +=
                4;
        }


        #
        # Auf vollständigen Frame warten.
        #
        last
            if length(
                $hash->{PARTIAL}
            ) < $pos + $pl;


        #
        # Payload entnehmen.
        #
        my $p =
            substr(
                $hash->{PARTIAL},
                $pos,
                $pl
            );


        #
        # Frame aus Empfangspuffer entfernen.
        #
        substr(
            $hash->{PARTIAL},
            0,
            $pos + $pl
        ) = "";


        Log3 $n, 5,
            "HomeConnectLocal ($n) - "
            . "WS RX frame "
            . "FIN=$fin "
            . "opcode="
            . sprintf("0x%X", $op)
            . " payload=$pl";


        #
        # ==========================================
        # Unmask
        # ==========================================
        #
        if ($masked) {

            my $u =
                '';


            for (
                my $i = 0;
                $i < $pl;
                $i++
            ) {

                $u .=
                    chr(
                        ord(
                            substr(
                                $p,
                                $i,
                                1
                            )
                        )
                        ^
                        ord(
                            substr(
                                $mask,
                                $i % 4,
                                1
                            )
                        )
                    );
            }


            $p =
                $u;
        }


        #
        # ==========================================
        # CLOSE
        # ==========================================
        #
        if ($op == 0x8) {

            my $code =
                "";

            my $reason =
                "";


            if (
                length($p) >= 2
            ) {

                $code =
                    unpack(
                        "n",
                        substr(
                            $p,
                            0,
                            2
                        )
                    );
            }


            if (
                length($p) > 2
            ) {

                $reason =
                    substr(
                        $p,
                        2
                    );
            }


            Log3 $n, 2,
                "HomeConnectLocal ($n) - "
                . "WebSocket CLOSE empfangen"
                . (
                    $code ne ""
                    ? " code=$code"
                    : ""
                )
                . (
                    $reason ne ""
                    ? " reason=$reason"
                    : ""
                );


            HomeConnectLocal_Close(
                $hash
            );

            return;
        }


        #
        # ==========================================
        # PING
        # ==========================================
        #
        if ($op == 0x9) {

            my $pong =
                HomeConnectLocal_WSFrame_Control(
                    0xA,
                    $p
                );


            syswrite(
                $s,
                $pong
            ) if defined($pong);


            next;
        }


        #
        # ==========================================
        # PONG
        # ==========================================
        #
        if ($op == 0xA) {

            next;
        }


        #
        # ==========================================
        # WebSocket Fragmentierung
        # ==========================================
        #


        #
        # Neuer Text- oder Binary-Frame.
        #
        if (
            $op == 0x1 ||
            $op == 0x2
        ) {

            #
            # FIN=0:
            # Beginn einer fragmentierten Nachricht.
            #
            if (!$fin) {

                $hash->{WS_FRAGMENT_OPCODE} =
                    $op;

                $hash->{WS_FRAGMENT_DATA} =
                    $p;


                Log3 $n, 4,
                    "HomeConnectLocal ($n) - "
                    . "WS Fragment gestartet "
                    . "opcode="
                    . sprintf("0x%X", $op)
                    . " bytes="
                    . length($p);


                next;
            }

            #
            # FIN=1:
            # Vollständige Nachricht in einem Frame.
            #
        }


        #
        # Continuation Frame
        #
        elsif ($op == 0x0) {

            #
            # Continuation ohne vorherigen Start.
            #
            if (
                !exists(
                    $hash->{WS_FRAGMENT_OPCODE}
                )
            ) {

                Log3 $n, 2,
                    "HomeConnectLocal ($n) - "
                    . "WS Continuation ohne "
                    . "Fragment-Start.";

                next;
            }


            $hash->{WS_FRAGMENT_DATA} .=
                $p;


            Log3 $n, 4,
                "HomeConnectLocal ($n) - "
                . "WS Fragment fortgesetzt "
                . "bytes="
                . length(
                    $hash->{WS_FRAGMENT_DATA}
                )
                . " FIN=$fin";


            #
            # Noch nicht fertig.
            #
            next
                if !$fin;


            #
            # Letztes Fragment:
            # komplette Nachricht herstellen.
            #
            $p =
                $hash->{WS_FRAGMENT_DATA};

            $op =
                $hash->{WS_FRAGMENT_OPCODE};


            delete
                $hash->{WS_FRAGMENT_DATA};

            delete
                $hash->{WS_FRAGMENT_OPCODE};


            Log3 $n, 3,
                "HomeConnectLocal ($n) - "
                . "WS fragmentierte Nachricht "
                . "vollständig "
                . "opcode="
                . sprintf("0x%X", $op)
                . " bytes="
                . length($p);
        }


        #
        # Andere Data-Opcodes ignorieren.
        #
        else {

            Log3 $n, 4,
                "HomeConnectLocal ($n) - "
                . "WS unbekannter Opcode "
                . sprintf("0x%X", $op);

            next;
        }


        #
        # ==========================================
        # Nur Text / Binary
        # ==========================================
        #
        next
            if $op != 0x1 &&
               $op != 0x2;


        #
        # ==========================================
        # AES
        # ==========================================
        #
        if (
            ($hash->{ConnectionType} // "TLS")
            eq "AES"
        ) {

            #
            # AES muss Binary sein.
            #
            next
                if $op != 0x2;


            Log3 $n, 5,
                "HomeConnectLocal ($n) - "
                . "AES vollständige WS Nachricht "
                . "bytes="
                . length($p);


            $p =
                HomeConnectLocal_AESDecrypt(
                    $hash,
                    $p
                );


            next
                if !defined($p);
        }


        #
        # ==========================================
        # JSON Payload
        # ==========================================
        #
        HomeConnectLocal_ProcessPayload(
            $hash,
            $p
        );
    }


    return;
}

##############################################
# Close
##############################################

sub HomeConnectLocal_Close {
    my ($hash) = @_;

    my $n =
        $hash->{NAME};


    if (
        $hash->{CD}
    ) {

        close(
            $hash->{CD}
        );

        delete
            $hash->{CD};
    }


    delete
        $main::selectlist{$n};

    delete
        $hash->{FD};

    delete
        $hash->{WSHandshake};

    delete
        $hash->{WS_FRAGMENT_DATA};

    delete
        $hash->{WS_FRAGMENT_OPCODE};


    $hash->{PARTIAL} =
        "";


    readingsSingleUpdate(
        $hash,
        "state",
        "closed",
        1
    );


    InternalTimer(
        time() + 10,
        "HomeConnectLocal_Connect",
        $hash,
        0
    );


    return;
}


##############################################
# Undefine
##############################################

sub HomeConnectLocal_Undefine {
    my ($hash) = @_;


    RemoveInternalTimer(
        $hash
    );


    if (
        $hash->{CD}
    ) {

        close(
            $hash->{CD}
        );

        delete
            $hash->{CD};
    }


    delete
        $main::selectlist{
            $hash->{NAME}
        };


    delete
        $hash->{FD};

    delete
        $hash->{WSHandshake};

    delete
        $hash->{WS_FRAGMENT_DATA};

    delete
        $hash->{WS_FRAGMENT_OPCODE};


    $hash->{PARTIAL} =
        "";


    return undef;
}


##############################################
# Set
##############################################

sub HomeConnectLocal_Set {
    my (
        $hash,
        @a
    ) = @_;


    my $n =
        $hash->{NAME};


    return
        "Unknown argument, choose one of "
        . "connect:noArg "
        . "disconnect:noArg "
        . "reloadMapping:noArg"
        if @a < 2;


    if (
        $a[1] eq "connect"
    ) {

        RemoveInternalTimer(
            $hash
        );


        HomeConnectLocal_Connect(
            $hash
        );


        return undef;
    }


    if (
        $a[1] eq "reloadMapping"
    ) {

        HomeConnectLocal_LoadMapping(
            $hash
        );


        return undef;
    }


    if (
        $a[1] eq "disconnect"
    ) {

        RemoveInternalTimer(
            $hash
        );


        HomeConnectLocal_Undefine(
            $hash
        );


        readingsSingleUpdate(
            $hash,
            "state",
            "disconnected",
            1
        );


        return undef;
    }


    return
        "Unknown argument $a[1], choose one of "
        . "connect:noArg "
        . "disconnect:noArg "
        . "reloadMapping:noArg";
}


##############################################
# Get
##############################################

sub HomeConnectLocal_Get {
    my (
        $hash,
        @a
    ) = @_;


    my $n =
        $hash->{NAME};


    return
        "Need an argument"
        if @a < 2;


    return
        $hash->{DeviceID}
        if $a[1] eq
           "deviceID";


    return
        ReadingsVal(
            $n,
            "state",
            "unknown"
        )
        if $a[1] eq
           "status";


    if (
        $a[1] eq "mapping"
    ) {

        return
            "not loaded"
            if !$hash->{MappingLoaded};


        return
              "prefix="
            . (
                $hash->{MappingPrefix}
                // ""
            )
            . " device="
            . (
                $hash->{MappingDeviceFile}
                // ""
            )
            . " feature="
            . (
                $hash->{MappingFeatureFile}
                // ""
            );
    }


    return
        "Unknown argument $a[1], choose one of "
        . "deviceID status mapping";
}


##############################################
# Attr
##############################################

sub HomeConnectLocal_Attr {
    my (
        $cmd,
        $name,
        $attr,
        $value
    ) = @_;


    my $hash =
        $defs{$name};


    return
        if !$hash;


    if (
        $attr =~
        /^(?:encryptionKey|connectionType|iv|disable|mappingDir|mappingPrefix|deviceType)$/
    ) {

        RemoveInternalTimer(
            $hash
        );


        if (
            $attr eq "disable" &&
            defined($value) &&
            $value
        ) {

            HomeConnectLocal_Undefine(
                $hash
            );


            readingsSingleUpdate(
                $hash,
                "state",
                "disabled",
                1
            );


            return undef;
        }


        if (
            $attr =~
            /^(?:mappingDir|mappingPrefix|deviceType)$/
        ) {

            HomeConnectLocal_LoadMapping(
                $hash
            );


            return undef;
        }


        InternalTimer(
            time() + 1,
            "HomeConnectLocal_Connect",
            $hash,
            0
        );
    }


    return undef;
}


1;