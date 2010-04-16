#!/usr/bin/perl

use strict;
use warnings;

use lib '../RTSP-Client/lib';
use lib 'lib';

use RTSP::Proxy;

my $proxy = RTSP::Proxy->new({
    rtsp_client => {
        address            => '10.0.1.31',
        media_path         => '/mpeg4/media.amp',
        client_port_range  => '6970-6971',
        transport_protocol => 'RTP/AVP;unicast',
    },
    transport_handler => {
        decode_rtp => 1,
        output_raw => 1,
        log_level => 4,
    },
    transport_handler_class => 'RTP',
    port   => 554,
    listen => 5,
    log_level => 4,
});

$proxy->run;

