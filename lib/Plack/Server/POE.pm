package Plack::Server::POE;

require v5.8.8;

use warnings;
use strict;

use HTTP::Message::PSGI;
use HTTP::Status qw(status_message);
use Plack::Util;
use POE qw(
    Component::Server::TCP
    Filter::HTTP::Parser
    Filter::Stream
);

sub new {
    my $class = shift;
    my $opt   = ref $_[0] eq 'HASH' ? shift : { @_ };
    $opt->{port} ||= 8080,
    $opt->{host} ||= 'localhost',

    return bless $opt, $class;
}

sub register_service {
    my ($self, $app) = @_;

    my $filter = POE::Filter::HTTP::Parser->new( type => 'server' );
    POE::Component::Server::TCP->new(
        Port               => $self->{port},
        Address            => $self->{host},
        ClientInputFilter  => $filter,
        ClientOutputFilter => 'POE::Filter::Stream',
        ClientInput        => sub {
            my ($kernel, $heap, $req) = @_[KERNEL, HEAP, ARG0];
            my $client = $heap->{client};

            my $env = req_to_psgi($req,
                SERVER_NAME         => $self->{host},
                SERVER_PORT         => $self->{port},
                'psgi.nonblocking'  => Plack::Util::TRUE,
                'psgi.runonce'      => Plack::Util::FALSE,
            );

            my $write = sub { $client->put($_[0]) };
            my $close = sub { $poe_kernel->yield('shutdown') };
            my $write_body = sub { Plack::Util::foreach($_[0], $write) };

            my $start_response = sub {
                my ($code, $headers) = @_;
                my $protocol = $req->protocol || 'HTTP/0.9';
                my $message = status_message($code);
                $write->("$protocol $code $message\r\n");

                while (@$headers) {
                    my $k = shift(@$headers);
                    my $v = shift(@$headers);
                    $write->("$k: $v\r\n");
                }

                $write->("\r\n");
            };

            my $response = Plack::Util::run_app($app, $env);

            if (ref $response eq 'CODE') {
                $response->(sub {
                    my ($status, $headers, $body) = @{+shift};
                    $start_response->($status, $headers);
                    if ($body) {
                        $write_body->($body);
                        $close->();
                    }
                    else {
                        return Plack::Util::inline_object(
                            write => $write,
                            close => $close,
                        );
                    }
                });
            }
            else {
                my ($status, $headers, $body) = @$response;
                $start_response->($status, $headers);
                $write_body->($body);
                $close->();
            }
        },
    );
}

sub run {
    my ($self, $app) = @_;
    $self->register_service($app);
    POE::Kernel->run;
}

1;

__END__

=head1 NAME

Plack::Server::POE - Plack Server implementation for POE

=head1 SYNOPSIS

    use Plack::Server::POE;

    my $server = Plack::Server::POE->new(
        host => $host,
        port => $port,
    );
    $server->run($app);

=head1 AUTHOR

Paul Driver, C<< <frodwith at cpan.org> >>

=head1 LICENSE

This module is licensed under the same terms as Perl itself.

=head1 SEE ALSO

L<Plack>

=cut
