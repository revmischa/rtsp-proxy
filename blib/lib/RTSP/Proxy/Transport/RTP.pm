package RTSP::Proxy::Transport::RTP;

use Moose;
with qw/RTSP::Proxy::Transport/;
extends 'Net::Server::Single';

use RTSP::Proxy::StreamBuffer;
use IO::Socket::INET;
use Carp qw/croak/;

has stream_buffer => (
    is => 'rw',
    isa => 'RTSP::Proxy::StreamBuffer',
    lazy => 1,
    builder => 'build_stream_buffer',
    handles => [qw/add_packet get_packet clear_packets/],
);

has client_socket => (
    is => 'rw',
    isa => 'IO::Socket::INET',
    handles => [qw/write/],
);

# how many packets to buffer
has stream_buffer_size => (
    is => 'rw',
    isa => 'Int',
    default => 128,
    lazy => 1,
);

# config defaults
sub default_values {
    return {
        proto        => 'udp',
        listen       => 1,
        port         => 6970,
        udp_recv_len => 4096,
    }
}

sub DEMOLISH {
    my $self = shift;
    
    my $client_sock = $self->client_socket;
    return unless $client_sock;
    $client_sock->shutdown(2);
}

sub generate_session_id {
    my $self = shift;
    my $ug = new Data::UUID;
    $self->session_id($ug->create_str);
    return $self->session_id;
}

sub build_client_socket {
    my $self = shift;
    
    my $peer_port = $self->session->client_port_start;
    my $peer_address = $self->session->client_address;
    
    if (! $peer_port || ! $peer_address) {
        $self->log(3, "calling build_client_socket() with unknown client information");
        return;
    }
    
    my $sock = IO::Socket::INET->new(
        PeerPort  => $peer_port,
        PeerAddr  => $peer_address,
        Proto     => 'udp',    
    ) or die "Can't bind: $@\n";
    
    return $sock;
}

sub build_stream_buffer {
    my $self = shift;

    my $sb = RTSP::Proxy::StreamBuffer->new(
        stream_buffer_size => $self->stream_buffer_size,
    );
    
    return $sb;
}

sub process_request {
    my $self = shift;
    
    my $packet_data = $self->{server}->{udp_data};
    $self->log(4, "got data of length " . (length $packet_data));
    
    $self->handle_packet($packet_data);
}

sub handle_packet {
    my ($self, $packet) = @_;
        
    # add packet to stream buffer
    $self->add_packet($packet);

    my $session = $self->session;
    if (! $session || ! $session->client_address || ! $session->client_port_start) {
        # no connection associated with this transport... not totally unexpected since UDP is stateless
        $self->log(3, "no valid session found for RTP transport in handle_packet()");
        return;
    }
    
    # forward packet to client
    my $client_addr = $session->client_address;
    $self->log(4, "forwarding packet to $client_addr");
    my $p = $self->get_packet or return;
    
    my $client_sock = $self->client_socket;
    if (! $client_sock) {
        $client_sock = $self->client_socket($self->build_client_socket);
    }
    return unless $client_sock;
    
    $self->log(3, "writing " . (length $p) . " bytes to $client_addr");
    $client_sock->write($p);
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);