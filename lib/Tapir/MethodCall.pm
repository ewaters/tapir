package Tapir::MethodCall;

=head1 NAME

Tapir::MethodCall - A method call

=head1 DESCRIPTION

The MethodCall object represents all the context and data necessary for a single method call within the API.  It's generated by a L<Tapir::Server> (most likely the L<Tapir::Server::ThriftAMQP>) when a new request is taken off the wire.

This is a generic module, to be used with any L<Tapir::Server>, but for simplicity sake we will act as though you'll be using the ThriftAMQP server, because you likely will be.

The MethodCall is a subclass of L<POE::Component::Sequence>, and will contain all the logic necessary to handle a request in it's action and callback sequences.

=cut

use strict;
use warnings;
use Scalar::Util qw(blessed);
use Time::HiRes qw(gettimeofday);
use base qw(POE::Component::Sequence Exporter);
use Carp;

our @EXPORT_OK = qw(dereference_fieldset);

use Class::MethodMaker [
    scalar => [qw(
        service
        method
        arguments
        message
        transport
        logger
        authentication
        server
    )],
];

=head1 Class Methods

=head2 I<new ($key, $value, ...)>

Call with a list of key/value pairs to setup a new method sequence.  See L</Accessors> for which keys are standard.

=cut

sub new {
    my ($class, %args) = @_;

    # Create the PoCo::Sequence first
    my $self = $class->SUPER::new();

    $args{arguments} ||= $args{message}->arguments;
    $args{method}    ||= $args{message}->method->idl;

    # Assign to my scalar accessors
    $self->$_($args{$_}) foreach keys %args;

    $self->heap_set(time_created => scalar(gettimeofday));

    return $self;
}

=head1 Object Methods

=head2 Accessors

=over 4

=item I<service> (type L<Thrift::IDL::Service>)

The IDL definition of the service.

=item I<method> (type L<Thrift::IDL::Method>)

The IDL definition of the method.

=item I<arguments> (type L<Thrift::Parser::FieldSet>)

The parsed message arguments.

=item I<message> (type L<Thrift::Parser::Message>)

The parsed message.

=item I<transport>

Meta data from the transport layer; includes header information and raw frames.  See L<POE::Component::Client::AMQP::Queue/subscribe>. Hash like:

=over 4

=item I<header_frame> (type  L<Net::AMQP::Protocol::Basic::ContentHeader>)

=item I<method_frame> (type L<Net::AMQP::Protocol::Basic::Publish>)

=item I<body_frames> (array of type  L<Net::AMQP::Frame::Body>)

=back

=item I<logger>

The logger inherited from L<Tapir::Server>

=item I<authentication>

The return value of L<Tapir::Server/is_valid_request>.

=item I<server>

The L<Tapir::Server> object.

=back

=head2 I<args>

Calls I<dereference_fieldset> on the message arguments with plain => 1 and insecure => 0.  Returns a hash.

=cut

sub args {
    my $self = shift;
    my $hash = dereference_fieldset($self->arguments, { plain => 1, insecure => 0 });
    return %$hash;
}

=head2 I<args_thrift>

Calls I<dereference_fieldset> on the message arguments with plain => 0 and insecure => 0.  Returns a hash.

=cut

sub args_thrift {
    my $self = shift;
    my $hash = dereference_fieldset($self->arguments, { plain => 0, insecure => 0 });
    return %$hash;
}

=head2 I<dereference_fieldset>

  my $hash = dereference_fieldset($parser_fieldset, { plain => 0, insecure => 0 });

Internal, recursive algorithm that will descend into the fieldset given and return a perl hash representing the structure.  The keys of the hash will be the 'name' method of the L<Thrift::Parser::Field>.  The value of the hash will be either the 'value' or 'value_plain' method of the L<Thrift::Parser::Field>, depending on the passed value of 'plain'.  If the value is another fieldset, this subroutine will call itself on that value for the stored value.

If 'insecure' is true, any fields which have a '@secure' flag in the documentation will have their values replaced with a placeholder string.

=cut

sub dereference_fieldset {
    my ($fieldset, $opt) = @_;
    $opt ||= {};

    my %return;
    foreach my $field (@{ $fieldset->fields }) {
        my $name            = $field->name;
        my $parser_type_obj = $field->value;

        if ($opt->{insecure} && $parser_type_obj->{spec}{doc}{secure}) {
            $return{$name} = '*** omitted ***';
        }
        elsif (ref($parser_type_obj->value) && blessed($parser_type_obj->value) && $parser_type_obj->value->isa('Thrift::Parser::FieldSet')) {
            $return{$name} = dereference_fieldset($parser_type_obj->value, $opt);
        }
        else {
            $return{$name} = $opt->{plain} ? $parser_type_obj->value_plain : $parser_type_obj;
        }
    }
    return \%return;
}

=head2 headers

Returns an arrayref of AMQP headers.  You probably want header() (below).

=cut

sub headers {
    my ($self) = @_;
    return $self->transport->{header_frame}->headers;
}

=head2 header

  my $status_queue = $self->header('Request-Status-Queue');

Returns the value of a header.  Case insensitive.

=cut

sub header {
    my ($self, $key) = @_;
    my $lc_key = lc $key;

    my $headers = $self->headers;
    foreach my $test_key (keys %$headers) {
        if ($lc_key eq lc($test_key)) {
            return $headers->{$test_key};
        }
    }
    return undef;
}

=head2 Finishing methods

These methods all store the scalar value passed as the method reply value and finish the sequence.  It's expected that the calling code will return after calling one of these finishing methods:

  return $method_call->set_result(145);

The result can be either a fully typed L<Thrift::Parser::Type> object or a untyped Perl scalar which will be cast into the expected value.

=over 4

=item I<set_result>

See L<Thrift::Parser::Message::compose_reply>.

=item I<set_error>

See L<Thrift::Parser::Message::compose_reply_application_exception>; throws an 'UNKNOWN' application error with the text of this error message.

=item I<set_exception>

Takes an IDL-defined exception (as a hash ref or blessed reference, see L<Thrift::Parser::Message::compose_reply_exception>) or L<TApplicationException>.

=back

=cut

sub set_result {
    my ($self, $result) = @_;

    $self->heap_set(result => $result);
    $self->finished();
}

sub set_exception {
    my ($self, $exception) = @_;

    $self->heap_set(exception => $exception);
    $self->finished();
}

sub set_error {
    my ($self, $error) = @_;

    $self->heap_set(error => $error);
    $self->finished();
}

sub add_rollback {
    my ($self, $func) = @_;

    # Execute it in an eval, as PoCo::Sequence doesn't
    $self->add_error_callback(sub {
        eval { $func->(); };
        if ($@) {
            $self->logger->info("add_rollback() had an error: $@");
        }
    });
}

1;
