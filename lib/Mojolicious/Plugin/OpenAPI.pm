package Mojolicious::Plugin::OpenAPI;
use Mojo::Base 'Mojolicious::Plugin';

use JSON::Validator::OpenAPI;
use constant DEBUG => $ENV{MOJO_OPENAPI_DEBUG} || 0;

our $VERSION = '0.02';

my $EXCEPTION = {errors => [{message => 'Internal server error.', path => '/'}], status => 500};
my $NOT_IMPLEMENTED = {errors => [{message => 'Not implemented.', path => '/'}], status => 501};
my $X_RE = qr{^x-};

has _validator => sub { JSON::Validator::OpenAPI->new; };

sub register {
  my ($self, $app, $config) = @_;
  my $api_spec = $self->_load_spec($app, $config);

  $app->helper('openapi.invalid_input' => sub { $self->_validate_request(@_) });
  $app->helper('openapi.spec'          => sub { shift->stash('openapi.op_spec') });
  $app->helper('reply.openapi'         => sub { $self->_reply(@_) });
  $app->hook(before_render => \&_before_render);

  $self->{log_level} = $ENV{MOJO_OPENAPI_LOG_LEVEL} || $config->{log_level} || 'warn';
  $self->_validator->schema($api_spec->data)->coerce($config->{coerce} // 1);
  $self->_add_routes($app, $api_spec, $config->{route});
}

sub _add_routes {
  my ($self, $app, $api_spec, $route) = @_;
  my $base_path = $api_spec->get('/basePath') || '/';
  my $paths = $api_spec->get('/paths');

  $route = $route->any($base_path) if $route and !$route->pattern->unparsed;
  $route = $app->routes->any($base_path) unless $route;
  $base_path = $api_spec->data->{basePath} = $route->to_string;
  $base_path =~ s!/$!!;

  $route->to('openapi.api_spec' => $api_spec);
  $route->get->to(cb => \&_reply_spec);

  for my $path (sort { length $a <=> length $b } keys %$paths) {
    next if $path =~ $X_RE;

    for my $http_method (keys %{$paths->{$path}}) {
      next if $http_method =~ $X_RE;
      my $op_spec = $paths->{$path}{$http_method};
      my $name    = $op_spec->{'x-mojo-name'} || $op_spec->{operationId};
      my $to      = $op_spec->{'x-mojo-to'};
      my $endpoint;

      if ($name and $endpoint = $route->root->find($name)) {
        $route->add_child($endpoint);
      }
      if (!$endpoint) {
        $endpoint = $route->any(_route_path($path, $op_spec));
        $endpoint->name($name) if $name;
      }

      $endpoint->to(ref $to eq 'ARRAY' ? @$to : $to) if $to;
      $endpoint->to($_ => $_->{default})
        for grep { $_->{in} eq 'path' and exists $_->{default} } @{$op_spec->{parameters} || []};
      $endpoint->to({'openapi.op_spec' => $op_spec});
      warn "[OpenAPI] Add route $http_method @{[$endpoint->render]}\n" if DEBUG;
    }
  }
}

sub _before_render {
  my ($c, $args) = @_;

  # TODO: Is this robust enough?
  # Want to disable this hook if the user does $c->render(template => "foo.html");
  return if !$args->{exception} and grep {/^\w+$/} keys %$args;
  return unless $c->stash('openapi.op_spec');
  my $format = $c->stash('format') || 'json';
  my $io = $args->{exception} ? $EXCEPTION : $NOT_IMPLEMENTED;
  $args->{status} = delete $io->{status};

  # TODO: Is $format a good idea? Was thinking someone might want to set
  # $c->stash(format => "xml") and it "should just work"
  $args->{$format} = $io;
}

sub _load_spec {
  my ($self, $app, $config) = @_;
  my $jv       = JSON::Validator->new;
  my $api_spec = $jv->schema($config->{url})->schema;
  my @errors
    = $jv->schema(JSON::Validator::OpenAPI::SPECIFICATION_URL())->validate($api_spec->data);
  die join "\n", "Invalid Open API spec:", @errors if @errors;
  warn "[OpenAPI] Loaded $config->{url}\n" if DEBUG;
  return $api_spec;
}

sub _log {
  my ($self, $c, $dir) = (shift, shift, shift);
  my $log_level = $self->{log_level};

  $c->app->log->$log_level(
    sprintf 'OpenAPI %s %s %s %s',
    $dir, $c->req->method,
    $c->req->url->path,
    Mojo::JSON::encode_json(@_)
  );
}

sub _reply {
  my ($self, $c, $status, $output) = @_;
  my $format = $c->stash('format') || 'json';
  return $c->render($format => $output, status => $status)
    unless my @errors
    = $self->_validator->validate_response($c, $c->openapi->spec, $status, $output);
  $self->_log($c, '>>>', \@errors);
  $c->render(json => {errors => \@errors, status => 500}, status => 500);
}

sub _reply_spec {
  my $c    = shift;
  my $spec = $c->stash('openapi.api_spec')->data;

  local $spec->{id};
  delete $spec->{id};
  local $spec->{host} = $c->req->url->to_abs->host_port;
  $c->render(json => $spec);
}

sub _route_path {
  my ($path, $op_spec) = @_;
  my %parameters = map { ($_->{name}, $_) } @{$op_spec->{parameters} || []};
  $path =~ s/{([^}]+)}/{
    my $pname = $1;
    my $type = $parameters{$pname}{'x-mojo-placeholder'} || ':';
    "($type$pname)";
  }/ge;
  return $path;
}

sub _validate_request {
  my ($self, $c, $args) = @_;
  my $op_spec = $c->openapi->spec;
  my @errors = $self->_validator->validate_request($c, $op_spec, $c->validation->output);

  if (@errors) {
    $self->_log($c, '<<<', \@errors);
    $c->render(json => {errors => \@errors, status => 400}, status => 400)
      if $args->{auto_render} // 1;
  }

  return @errors;
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::OpenAPI - OpenAPI / Swagger plugin for Mojolicious

=head1 SYNOPSIS

  use Mojolicious::Lite;

  # Will be moved under "basePath", resulting in "POST /api/echo"
  post "/echo" => sub {
    my $c = shift;
    return if $c->openapi->invalid_input;
    return $c->reply->openapi(200 => $c->validation->param("body"));
  }, "echo";

  # Load specification and start web server
  plugin OpenAPI => {url => "data://main/api.json"};
  app->start;

  __DATA__
  @@ api.json
  {
    "swagger" : "2.0",
    "info" : { "version": "0.8", "title" : "Pets" },
    "schemes" : [ "http" ],
    "basePath" : "/api",
    "paths" : {
      "/echo" : {
        "post" : {
          "x-mojo-name" : "echo",
          "parameters" : [
            { "in": "body", "name": "body", "schema": { "type" : "object" } }
          ],
          "responses" : {
            "200": {
              "description": "Echo response",
              "schema": { "type": "object" }
            }
          }
        }
      }
    }
  }

=head1 DESCRIPTION

L<Mojolicious::Plugin::OpenAPI> is L<Mojolicious::Plugin> that add routes and
input/output validation to your L<Mojolicious> application based on a OpenAPI
(Swagger) specification.

Have a look at the L</SEE ALSO> for references to more documentation, or jump
right to the L<tutorial|Mojolicious::Plugin::OpenAPI::Guides::Tutorial>.

L<Mojolicious::Plugin::OpenAPI> will replace L<Mojolicious::Plugin::Swagger2>.

This plugin is currently EXPERIMENTAL.

=head1 HELPERS

=head2 openapi.invalid_input

  @errors = $c->openapi->invalid_input;
  @errors = $c->openapi->invalid_input({auto_render => 0});

Used to validate a request. C<@errors> holds a list of
L<JSON::Validator::Error> objects or empty list on valid input. Setting
C<auto_render> to a false value will disable the internal auto rendering. This
is useful if you want to craft a custom resonse.

Validated input parameters will be copied to
C<Mojolicious::Controller/validation>, which again can be extracted by the
"name" in the parameters list from the spec. Example:

  # specification:
  "parameters": [{"in": "body", "name": "whatever", "schema": {"type": "object"}}],

  # controller
  my $body = $c->validation->param("whatever");

=head2 openapi.spec

  $hash = $c->openapi->spec;

Returns the OpenAPI specification for the current route. Example:

  {
    "paths": {
      "/pets": {
        "get": {
          // This datastructure is returned
        }
      }
    }
  }

=head2 reply.openapi

  $c->reply->openapi($status => $output);

Will L<validate|/openapi.validate> C<$output> before passing it on to
L<Mojolicious::Controller/render>. Note that C<$output> will be passed on using
the L<format|Mojolicious::Guides::Rendering/Content type> key in stash, which
defaults to "json". This also goes for L<auto-rendering|/Controller>. Example:

  my $format = $c->stash("format") || "json";
  $c->render($format => \%output);

C<$status> is a HTTP status code.

=head1 METHODS

=head2 register

  $self->register($app, \%config);

Loads the OpenAPI specification, validates it and add routes to
L<$app|Mojolicious>. It will also set up L</HELPERS> and adds a
L<before_render|Mojolicious/before_render> hook for auto-rendering of error
documents.

C<%config> can have:

=over 2

=item * coerce

See L<JSON::Validator/coerce> for possible values that C<coerce> can take.

Default: 1

=item * log_level

C<log_level> is used when logging invalid request/response error messages.

Default: "warn".

=item * route

C<route> can be specified in case you want to have a protected API. Example:

  $app->plugin(OpenAPI => {
    route => $app->routes->under("/api")->to("user#auth"),
    url   => $app->home->rel_file("cool.api"),
  });

=item * url

See L<JSON::Validator/schema> for the different C<url> formats that is
accepted.

=back

=head1 TODO

This plugin is still a big rough on the edges, but I decided to release it on
CPAN so people can start playing around with it.

=over 2

=item * Add L<WebSockets support|https://github.com/jhthorsen/mojolicious-plugin-openapi/compare/websocket>.

=item * Add support for /api.html (human readable documentation)

=item * Never add support for "x-mojo-around-action", but possibly "before action".

=back

=head1 AUTHOR

Jan Henning Thorsen

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2016, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

=over 2

=item * L<Mojolicious::Plugin::OpenAPI::Guides::Tutorial>

=item * L<http://thorsen.pm/perl/programming/2015/07/05/mojolicious-swagger2.html>.

=item * L<OpenAPI specification|https://openapis.org/specification>

=item * L<Mojolicious::Plugin::Swagger2>.

=back

=cut
