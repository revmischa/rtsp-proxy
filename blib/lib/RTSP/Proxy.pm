package RTSP::Proxy;

use Moose;
extends 'Net::Server::PreFork';

use RTSP::Proxy::Session;
use Carp qw/croak/;

our $VERSION = '0.06';

=head1 NAME

RTSP::Proxy - Simple RTSP proxy server

=head1 SYNOPSIS

  use RTSP::Proxy;
  my $proxy = RTSP::Proxy->new({
      rtsp_client => {
          address            => '10.0.1.105',
          media_path         => '/mpeg4/media.amp',
          client_port_range  => '6970-6971',
          transport_protocol => 'RTP/AVP;unicast',
      },
      port   => 554,
      listen => 5,
  });
  
  $proxy->run;

=head1 DESCRIPTION

This module is a simple RTSP proxy based on L<Net::Server> and L<RTSP::Client>.

When a client connects and sends commands to the server, it will pass them through the RTSP client and return the results back.

This has only been tested with VLC and Axis IP cameras, it may not work with your setup. Patches and feedback welcome.

Note: you will need to be root to bind to port 554, you may drop privs if you wish. See the configuration options in L<Net::Server> for more details.

=head2 EXPORT

None by default.

=head2 METHODS

=over 4

=cut

has session => (
    is => 'rw',
    isa => 'RTSP::Proxy::Session',
);

sub process_request {
    my $self = shift;
    
    my $method;
    my $uri;
    my $proto;
    my $headers = {};
    
    READ: while (my $line = <STDIN>) {
        $self->log(5, "got line: $line");
        
        unless ($method) {
            # first line should be method
            ($method, $uri, $proto) = $line =~ m!(\w+)\s+(\S+)(?:\s+(\S+))?\r\n!ism;
            
            $self->log(4, "method: $method, uri: $uri, protocol: $proto");
            
            unless ($method && $uri && $proto =~ m!RTSP/1.\d!i) {
                $self->log(1, "Invalid request: $line");
                return $self->return_status(403, 'Bad request');
            }
            next READ;
        } else {
            goto DONE if $line eq "\r\n";
            
            # header
            my ($header_name, $header_value) = $line =~ /^([-A-Za-z0-9]+)\s*:\s*(.*)$/;
            unless ($header_name) {
                $self->log(1, "Invalid header: $line");
                next;
            }
            
            $headers->{$header_name} = $header_value;
            next READ;
        }
        
        DONE:
        last unless $method && $proto;
    
        $method = uc $method;
        
    
        # get/create session
        my $session;
        if ($self->{server}{session}) {
            $session = $self->{server}{session};
        } else {
            my $client_settings = $self->{server}{rtsp_client} or die "Could not find client configuration";
        
            my $transport_handler_class = $self->{server}{transport_handler_class};
            croak "build_transport_handler() called without transport_handler_class being defined"
                unless $transport_handler_class;

            # get client address
            my $sock = $self->{server}{client};
            my $client_address = $sock->peerhost;

            # create RTSP session object
            $self->log(3, "creating session");
            $session = RTSP::Proxy::Session->new(
                client_address => $client_address,
                rtsp_client_opts => $client_settings,
                media_uri => $uri,
                transport_handler_class => $transport_handler_class,
            );
            
            # save session
            $self->{server}{session} = $session;
        }
    
        if ($method eq 'PLAY') {
            $session->rtsp_client->reset;
        }
        
        # parse out setup info
        my ($client_port_start, $client_port_end);
        if ($method eq 'SETUP') {
            # parse out the client requested ports
            my $transport = $headers->{Transport} || $headers->{transport} || '';
            $self->log(4, "transport: '$transport'");
            ($client_port_start, $client_port_end) = $transport =~ /client_port=(\d+)(?:-(\d+))?/i;
            
            # rewrite the client port range
            if ($client_port_start) {
                $client_port_end ||= $client_port_start;
                
                # totally broken!
                my $proxy_port_start = "6970";
                my $proxy_port_end   = "6971";
                
                # lol!
                my $port_range = "${proxy_port_start}-$proxy_port_end";
                $transport =~ s/client_port=((?:\d+)(?:-(?:\d+)))?/client_port=$port_range/ims;
                $self->log(3, "rewriting transport request: $transport");
                
                # replace transport header with our transport specification
                delete $headers->{Transport};
                delete $headers->{transport};
                $headers->{Transport} = $transport;
                
                $self->log(3, "setting session client port $client_port_start");
                $session->client_port_start($client_port_start);
                $session->client_port_end($client_port_end);
                
                # now ready to run server to proxy media transport
                $session->run_transport_handler_server;
            }
        }
                
        $self->proxy_request($method, $uri, $session, $headers);
    
        # so we can reuse the client for more requests
        if ($method eq 'SETUP' || $method eq 'DESCRIBE' || $method eq 'TEARDOWN') {
            $self->log(4, "resetting rtsp client");
            $session->rtsp_client->reset;
        }
        
        if ($method eq 'TEARDOWN') {
            delete $self->{server}{session};
        }
    
        $method = '';
        $uri = '';
        $proto = '';
        $headers = {};
    }
}

sub proxy_request {
    my ($self, $method, $uri, $session, $headers) = @_;
    
    $self->log(4, "proxying $method / $uri to " . $session->rtsp_client->address);
    
    my $client = $session->rtsp_client;
    
    unless ($client->connected) {
        # open a connection
        unless ($client->open) {
            $self->log(0, "Failed to connect to camera: $!");
            return $self->return_status(404, "Resource not found");
        }
    }
    
    # pass through some headers
    foreach my $header_name (qw/
        Accept Bandwidth Accept-Language ClientChallenge PlayerStarttime RegionData
        GUID ClientID Transport x-retransmit x-dynamic-rate x-transport-options Session
        Range/) {
            
        my $header_value = $headers->{$header_name};
        next unless defined $header_value;
        $self->chomp_line(\$header_value);
        $client->add_req_header($header_name, $header_value)
            unless $client->get_req_header($header_name) &&
            $client->get_req_header($header_name) eq $header_value;
    }
    
    # do request
    $self->log(3, "proxying $method");
    my $ok;
    my $body;
    if ($method eq 'SETUP') {
        $ok = $client->setup;
    } elsif ($method eq 'DESCRIBE') {
        # proxy body response
        $body = $client->describe;
    } elsif ($method eq 'OPTIONS') {
        $ok = $client->options;
    } elsif ($method eq 'TEARDOWN') {
        $ok = $client->teardown;
    } else {
        $ok = $client->request($method);
    }
    
    my $status_message = $client->status_message;
    my $status_code = $client->status;
    
    $self->log(4, "$status_code $status_message - got headers: " . $client->_rtsp->headers_string . "\n");
    
    unless ($status_code) {
        $status_code = 405;
        $status_message = "Bad request";
    }
    
    my $res = '';

    # return status
    $res .= "RTSP/1.0 $status_code $status_message\r\n";
    
    # pass some headers back    
    foreach my $header_name (qw/
        Content-Type Content-Base Public Allow Transport Session
        Rtp-Info Range transport/) {
        my $header_values = $client->get_header($header_name);
        next unless defined $header_values;
        foreach my $val (@$header_values) {
            $self->log(4, "header: $header_name, value: '$val'");
            $self->chomp_line(\$val);
            
            $self->rewrite_transport_response($session, \$val)
                if lc $header_name eq 'transport';
            
            $res .= "$header_name: $val\r\n";
        }
    }
    
    # respond with correct CSeq                                                                                                                                                     
    my $cseq = $headers->{CSeq} || $headers->{Cseq} || $headers->{cseq};
    if ($cseq) {
        $self->chomp_line(\$cseq);
        $res .= "cseq: $cseq\r\n";
    }
    
    $self->write($res, $body);
}

sub write {
    my ($self, $headers_string, $body) = @_;

    my $res = $headers_string;

    if ($body) {
        $self->chomp_line(\$body);
        $res .= "Content-Length: " . length($body) . "\r\n\r\n$body";
    } else {
        $res .= "\r\n";
    }

    my $sock = $self->{server}->{client} or die "Could not find client socket";
    $sock->write("$res");

    $self->log(4, ">>$res\n");
}

sub rewrite_transport_response {
    my ($self, $session, $respref) = @_;
    return unless $respref && $$respref;
    
    $self->log(3, "transport response: $$respref");
    
    my $client_port_start = $session->client_port_start;
    my $client_port_end   = $session->client_port_end;
    
    return unless $client_port_start && $client_port_end;
    
    my $port_range = "${client_port_start}-$client_port_end";
    $$respref =~ s/client_port=((?:\d+)(?:-(?:\d+)))?/client_port=$port_range/ims;
    $self->log(3, "rewriting transport response: $$respref");
}

# clean up stuff!
sub post_client_connection_hook {
    my $self = shift;
    
    $self->log(3, "client connection closed");
    
    my $session = $self->{server}{session};
    if ($session) {
        delete $self->{server}{session};
    }
}

#####

sub return_status {
    my ($self, $code, $msg) = @_;
    print STDOUT "$code $msg\r\n";
    $self->log(3, "Returning status $code $msg");
}

sub chomp_line {
    my ($self, $lineref) = @_;
    $$lineref =~ s/([\r\n]+)$//sm;
}

sub default_values {
    return {
        proto        => 'tcp',
        listen       => 3,
        port         => 554,
    }
}

sub options {
    my $self     = shift;
    my $prop     = $self->{'server'};
    my $template = shift;

    ### setup options in the parent classes
    $self->SUPER::options($template);
    
    
    ### rtsp client args
    my $client = $prop->{rtsp_client}
        or croak "No rtsp_client definition specified";
    
    $template->{rtsp_client} = \ $prop->{rtsp_client};
    
    
    ### transport class
    my $tc = $prop->{'transport_handler_class'} || 'RTP';
    $tc = "RTSP::Proxy::Transport::$tc";
    eval "use $tc; 1;" or die $@;
    
    $prop->{'transport_handler_class'} = $tc;
    $template->{'transport_handler_class'} = \ $prop->{'transport_handler_class'};
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);

__END__




=head1 SEE ALSO

L<RTSP::Client>

=head1 AUTHOR

Mischa Spiegelmock, E<lt>revmischa@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Mischa Spiegelmock

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=head1 GUINEAS

SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS 8DDDDDDDDDDDDDDDDDDDDDDDD horseBERD

=cut
